@testable import App
import XCTVapor
import Fluent
import ChessOnline

/// Abuse protection for the auth surface (#32): the per-IP rate limit on
/// /auth/* and the abandoned-guest cleanup job.
final class AuthAbuseTests: XCTestCase {
    var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
    }

    // MARK: - Limiter semantics

    func testLimiterAdmitsUpToLimitThenRefusesUntilWindowResets() async {
        let limiter = FixedWindowRateLimiter(limit: 3, window: 60)
        let start = Date()

        for i in 0..<3 {
            let verdict = await limiter.check("ip", now: start.addingTimeInterval(Double(i)))
            XCTAssertEqual(verdict, .allowed, "request \(i + 1) is within the limit")
        }
        let refused = await limiter.check("ip", now: start.addingTimeInterval(10))
        XCTAssertEqual(refused, .limited(retryAfter: 50), "window opened at t=0, so t=10 waits 50s")

        // A fresh window admits again.
        let afterReset = await limiter.check("ip", now: start.addingTimeInterval(61))
        XCTAssertEqual(afterReset, .allowed)
    }

    func testLimiterKeysAreIndependent() async {
        let limiter = FixedWindowRateLimiter(limit: 1, window: 60)
        let now = Date()

        let first = await limiter.check("ip-a", now: now)
        XCTAssertEqual(first, .allowed)
        if case .allowed = await limiter.check("ip-a", now: now) {
            XCTFail("second request from the same key must be limited")
        }
        let otherKey = await limiter.check("ip-b", now: now)
        XCTAssertEqual(otherKey, .allowed, "another key has its own window")
    }

    // MARK: - HTTP surface

    func testAuthEndpointsReturn429PastTheLimit() async throws {
        // Test requests carry no socket address, so they all share one
        // bucket — which is exactly what this test needs.
        app.authRateLimiter = FixedWindowRateLimiter(limit: 2, window: 60)

        for _ in 0..<2 {
            try await app.test(.POST, "auth/register", beforeRequest: { req in
                try req.content.encode(RegisterRequest(displayName: nil), as: .json)
            }, afterResponse: { res async in
                XCTAssertEqual(res.status, .ok)
            })
        }

        // Third request in the window: refused, with retry guidance, and no
        // account created.
        let usersBefore = try await User.query(on: app.db).count()
        try await app.test(.POST, "auth/register", beforeRequest: { req in
            try req.content.encode(RegisterRequest(displayName: nil), as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .tooManyRequests)
            XCTAssertNotNil(res.headers["Retry-After"].first)
        })
        let usersAfter = try await User.query(on: app.db).count()
        XCTAssertEqual(usersBefore, usersAfter, "a limited request must not create an account")

        // The limit covers the whole auth group, not just register.
        try await app.test(.POST, "auth/refresh", beforeRequest: { req in
            try req.content.encode(RefreshRequest(refreshToken: "irrelevant"), as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .tooManyRequests)
        })
    }

    func testProxyHeaderKeysPreferFlyClientIP() async throws {
        // Behind Fly's proxy, Fly-Client-IP is the canonical client address;
        // the rightmost X-Forwarded-For entry there is the app's OWN IP and
        // would fold every client into one shared bucket.
        setenv("TRUST_PROXY_HEADERS", "1", 1)
        defer { unsetenv("TRUST_PROXY_HEADERS") }
        app.authRateLimiter = FixedWindowRateLimiter(limit: 1, window: 60)

        // Two clients sharing the Fly-style XFF tail each get their own window…
        for client in ["203.0.113.7", "203.0.113.8"] {
            try await app.test(.POST, "auth/register", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "Fly-Client-IP", value: client)
                req.headers.replaceOrAdd(name: "X-Forwarded-For", value: "\(client), 66.241.124.1")
                try req.content.encode(RegisterRequest(displayName: nil), as: .json)
            }, afterResponse: { res async in
                XCTAssertEqual(res.status, .ok, "distinct Fly-Client-IPs must not share a bucket")
            })
        }

        // …and the same client is limited on a repeat attempt.
        try await app.test(.POST, "auth/register", beforeRequest: { req in
            req.headers.replaceOrAdd(name: "Fly-Client-IP", value: "203.0.113.7")
            try req.content.encode(RegisterRequest(displayName: nil), as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .tooManyRequests)
        })
    }

    func testProxyHeaderKeysFallBackToLastForwardedEntry() async throws {
        // Conventional reverse proxies (nginx et al.) append the peer they
        // saw as the last X-Forwarded-For entry and set no Fly-Client-IP.
        // Client-controlled earlier entries must not affect the key.
        setenv("TRUST_PROXY_HEADERS", "1", 1)
        defer { unsetenv("TRUST_PROXY_HEADERS") }
        app.authRateLimiter = FixedWindowRateLimiter(limit: 1, window: 60)

        try await app.test(.POST, "auth/register", beforeRequest: { req in
            req.headers.replaceOrAdd(name: "X-Forwarded-For", value: "10.9.9.9, 198.51.100.4")
            try req.content.encode(RegisterRequest(displayName: nil), as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
        })
        try await app.test(.POST, "auth/register", beforeRequest: { req in
            req.headers.replaceOrAdd(name: "X-Forwarded-For", value: "10.8.8.8, 198.51.100.4")
            try req.content.encode(RegisterRequest(displayName: nil), as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .tooManyRequests,
                           "same proxy-appended peer shares the bucket despite differing spoofable entries")
        })
    }

    // MARK: - Guest cleanup

    /// Seeds a user created `daysAgo` days in the past. `createdAt` is a
    /// Fluent auto-timestamp, so it's backdated with a second save.
    private func seedUser(daysAgo: Double, appleID: String? = nil) async throws -> User {
        let user = User(displayName: "Guest-Test", appleUserID: appleID)
        try await user.save(on: app.db)
        user.createdAt = Date().addingTimeInterval(-daysAgo * 24 * 3600)
        try await user.save(on: app.db)
        return user
    }

    private func seedRefreshToken(for user: User, issuedDaysAgo: Double) async throws {
        let token = RefreshToken(
            userID: try user.requireID(),
            tokenHash: RefreshToken.hash(UUID().uuidString),
            expiresAt: Date().addingTimeInterval(RefreshToken.lifetime - issuedDaysAgo * 24 * 3600)
        )
        try await token.save(on: app.db)
    }

    func testCleanupDeletesOnlyAbandonedGuests() async throws {
        // Deleted: old guest, no games, token last refreshed 40 days ago.
        let abandoned = try await seedUser(daysAgo: 60)
        try await seedRefreshToken(for: abandoned, issuedDaysAgo: 40)

        // Deleted: old guest with no credential left at all.
        let tokenless = try await seedUser(daysAgo: 60)

        // Kept: refreshed recently (active player between games).
        let active = try await seedUser(daysAgo: 60)
        try await seedRefreshToken(for: active, issuedDaysAgo: 2)

        // Kept: has a finished game on record.
        let veteran = try await seedUser(daysAgo: 60)
        try await GameRecord(
            whiteID: try veteran.requireID(), blackID: UUID(),
            whiteName: veteran.displayName, blackName: "Someone",
            result: "whiteWins", endReason: "checkmate", uciMoves: "e2e4"
        ).save(on: app.db)

        // Kept: linked to an Apple ID (recoverable, not a throwaway).
        let linked = try await seedUser(daysAgo: 60, appleID: "apple-subject")

        // Kept: too young to judge.
        let fresh = try await seedUser(daysAgo: 5)

        let removed = try await GuestAccountCleanup.run(on: app.db)
        XCTAssertEqual(removed, 2)

        let remaining = Set(try await User.query(on: app.db).all().map { try $0.requireID() })
        XCTAssertFalse(remaining.contains(try abandoned.requireID()))
        XCTAssertFalse(remaining.contains(try tokenless.requireID()))
        XCTAssertTrue(remaining.contains(try active.requireID()))
        XCTAssertTrue(remaining.contains(try veteran.requireID()))
        XCTAssertTrue(remaining.contains(try linked.requireID()))
        XCTAssertTrue(remaining.contains(try fresh.requireID()))

        // The deleted accounts' tokens went with them.
        let orphanTokens = try await RefreshToken.query(on: app.db)
            .filter(\.$user.$id == abandoned.requireID())
            .count()
        XCTAssertEqual(orphanTokens, 0)
    }

    func testCleanupKeepsGuestWhoPlayedAsBlack() async throws {
        // The game-history check must cover both colors.
        let blackPlayer = try await seedUser(daysAgo: 60)
        try await GameRecord(
            whiteID: UUID(), blackID: try blackPlayer.requireID(),
            whiteName: "Someone", blackName: blackPlayer.displayName,
            result: "blackWins", endReason: "resignation", uciMoves: "e2e4"
        ).save(on: app.db)

        try await GuestAccountCleanup.run(on: app.db)
        let survivor = try await User.find(blackPlayer.requireID(), on: app.db)
        XCTAssertNotNil(survivor)
    }

    func testCleanupIsIdempotentAndQuietWhenNothingQualifies() async throws {
        _ = try await seedUser(daysAgo: 5)
        let first = try await GuestAccountCleanup.run(on: app.db)
        let second = try await GuestAccountCleanup.run(on: app.db)
        XCTAssertEqual(first, 0)
        XCTAssertEqual(second, 0)
    }

    func testCleanupReapsAcrossBatchBoundaries() async throws {
        // Regression for #155 (M3): the pre-batch code sent every candidate ID
        // in one IN(…) query, which threw past the driver's bind ceiling and
        // — swallowed by the scheduler — halted reaping forever. Seed more
        // deletable guests than one batch holds and confirm the batched loop
        // reaps every one across boundaries. batchSize is injected small so the
        // test doesn't need thousands of rows.
        for _ in 0..<5 {
            _ = try await seedUser(daysAgo: 60) // old, no token, no game → deletable
        }
        let removed = try await GuestAccountCleanup.run(on: app.db, batchSize: 2)
        XCTAssertEqual(removed, 5, "every deletable guest is reaped across the 2+2+1 batches")
        let remaining = try await User.query(on: app.db).count()
        XCTAssertEqual(remaining, 0, "no abandoned guest left behind")
    }
}
