@testable import App
import XCTVapor
import Fluent
import SQLKit
import ChessOnline

/// Abuse protection for the auth surface (#32, #79): the per-IP rate limit
/// on /auth/* — counted in the shared database so every instance draws from
/// one budget — and the abandoned-guest cleanup job.
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

    /// A fixed instant on a bucket boundary (divisible by the 60s window),
    /// so tests control exactly where in a bucket each request lands.
    private let bucketStart = Date(timeIntervalSince1970: 60_000_000)

    func testLimiterAdmitsUpToLimitThenRefusesUntilWindowPasses() async throws {
        let limiter = SlidingWindowRateLimiter(limit: 3, window: 60)

        for i in 0..<3 {
            let verdict = try await limiter.check("ip", on: app.db, now: bucketStart.addingTimeInterval(Double(i)))
            XCTAssertEqual(verdict, .allowed, "request \(i + 1) is within the limit")
        }
        guard case .limited(let retryAfter) = try await limiter.check("ip", on: app.db, now: bucketStart.addingTimeInterval(10)) else {
            return XCTFail("request past the limit must be refused")
        }
        // With no previous bucket and current saturated at 4, a quiet client
        // is admitted at fraction g = 1 − (limit−1)/current = 0.5 of the
        // next bucket: (1 − 10/60 + 0.5) × 60 = 80s.
        XCTAssertEqual(retryAfter, 80, accuracy: 0.001, "retry guidance matches the decay math")

        // Two windows later both buckets have aged out; the key is admitted again.
        let afterReset = try await limiter.check("ip", on: app.db, now: bucketStart.addingTimeInterval(121))
        XCTAssertEqual(afterReset, .allowed)
    }

    func testWindowBoundaryBurstIsSmoothed() async throws {
        // A fixed window admits `limit` at the end of one window and `limit`
        // more right after the boundary — 2× the limit in seconds. The
        // sliding window weighs the previous bucket in, decaying as the new
        // bucket progresses.
        let limiter = SlidingWindowRateLimiter(limit: 4, window: 60)

        for i in 0..<4 {
            let lateBurst = try await limiter.check("ip", on: app.db, now: bucketStart.addingTimeInterval(55 + Double(i)))
            XCTAssertEqual(lateBurst, .allowed, "the first 4 requests fit the budget")
        }
        if case .allowed = try await limiter.check("ip", on: app.db, now: bucketStart.addingTimeInterval(61)) {
            XCTFail("just past the boundary the previous bucket still weighs ~full; a fresh burst must be refused")
        }
        // Halfway into the new bucket the old one has decayed enough to admit.
        let afterDecay = try await limiter.check("ip", on: app.db, now: bucketStart.addingTimeInterval(91))
        XCTAssertEqual(afterDecay, .allowed)
    }

    func testLimiterKeysAreIndependent() async throws {
        let limiter = SlidingWindowRateLimiter(limit: 1, window: 60)

        let first = try await limiter.check("ip-a", on: app.db, now: bucketStart)
        XCTAssertEqual(first, .allowed)
        if case .allowed = try await limiter.check("ip-a", on: app.db, now: bucketStart) {
            XCTFail("second request from the same key must be limited")
        }
        let otherKey = try await limiter.check("ip-b", on: app.db, now: bucketStart)
        XCTAssertEqual(otherKey, .allowed, "another key has its own window")
    }

    func testLimitIsSharedAcrossLimiterInstances() async throws {
        // Two limiters over one database stand in for two server instances:
        // the budget must be shared, not `limit × instances` (#79).
        let one = SlidingWindowRateLimiter(limit: 2, window: 60)
        let two = SlidingWindowRateLimiter(limit: 2, window: 60)

        let first = try await one.check("ip", on: app.db, now: bucketStart)
        XCTAssertEqual(first, .allowed)
        let second = try await two.check("ip", on: app.db, now: bucketStart.addingTimeInterval(1))
        XCTAssertEqual(second, .allowed)
        if case .allowed = try await two.check("ip", on: app.db, now: bucketStart.addingTimeInterval(2)) {
            XCTFail("an instance must see requests counted by its peers")
        }
        if case .allowed = try await one.check("ip", on: app.db, now: bucketStart.addingTimeInterval(3)) {
            XCTFail("the refusal holds on every instance")
        }
    }

    func testRefusalsSaturateOnePastTheLimit() async throws {
        // Hammering must not grow the counter without bound: the count caps
        // at limit + 1, so once traffic stops the key recovers after one
        // rollover (old fixed-window behavior) and Retry-After stays honest.
        let limiter = SlidingWindowRateLimiter(limit: 2, window: 60)
        for i in 0..<8 {
            _ = try await limiter.check("ip", on: app.db, now: bucketStart.addingTimeInterval(Double(i)))
        }
        struct Row: Decodable { var count: Int }
        let sql = try XCTUnwrap(app.db as? any SQLDatabase)
        let row = try await sql.raw("""
        SELECT "count" FROM "auth_rate_windows" WHERE "key" = \(bind: "ip")
        """).first(decoding: Row.self)
        XCTAssertEqual(try XCTUnwrap(row).count, 3, "counter saturates at limit + 1")
    }

    func testLimiterFailsClosedWhenStoreIsUnavailable() async throws {
        // A store that can't be queried must refuse to vouch for a verdict
        // rather than silently admitting — the check throws instead of
        // returning `.allowed`.
        let limiter = SlidingWindowRateLimiter(limit: 5, window: 60)
        let sql = try XCTUnwrap(app.db as? any SQLDatabase)
        try await sql.raw(#"DROP TABLE "auth_rate_windows""#).run()

        do {
            _ = try await limiter.check("ip", on: app.db, now: bucketStart)
            XCTFail("a query against a missing table must throw, not admit")
        } catch {
            // Any thrown error is fail-closed; the specific type is the
            // driver's own "no such table" / "relation does not exist".
        }

        // A shared, persistent database (unlike per-test in-memory SQLite)
        // must not stay broken for whichever test runs next.
        try await CreateAuthRateWindow().prepare(on: app.db)
    }

    func testMiddlewareFailsClosedWhenStoreIsUnavailable() async throws {
        // The HTTP-facing half of the same guarantee: a broken store must
        // turn into a non-2xx response before the route handler runs, not
        // a quietly-admitted request.
        app.authRateLimiter = SlidingWindowRateLimiter(limit: 5, window: 60)
        let sql = try XCTUnwrap(app.db as? any SQLDatabase)
        try await sql.raw(#"DROP TABLE "auth_rate_windows""#).run()

        let usersBefore = try await User.query(on: app.db).count()
        try await app.test(.POST, "auth/register", beforeRequest: { req in
            try req.content.encode(RegisterRequest(displayName: nil), as: .json)
        }, afterResponse: { res async in
            XCTAssertFalse((200...299).contains(Int(res.status.code)),
                           "a limiter that can't count must not let the request through")
        })
        let usersAfter = try await User.query(on: app.db).count()
        XCTAssertEqual(usersBefore, usersAfter, "no account is created when the store is down")

        // A shared, persistent database (unlike per-test in-memory SQLite)
        // must not stay broken for whichever test runs next.
        try await CreateAuthRateWindow().prepare(on: app.db)
    }

    func testConcurrentRequestsShareOneAtomicBudget() async throws {
        // Sequential awaits (the tests above) can't catch a check-then-act
        // race: a non-atomic "SELECT count, then INSERT/UPDATE" store would
        // let concurrent requests all read the same stale count and all
        // proceed. Firing real concurrent requests at one shared connection
        // pool is the only way to exercise that race, and the single atomic
        // upsert (INSERT … ON CONFLICT … DO UPDATE … RETURNING) must hold
        // the budget to exactly `limit` admissions regardless of ordering.
        let limiter = SlidingWindowRateLimiter(limit: 10, window: 60)
        let attempts = 40
        let db = app.db
        let now = bucketStart

        let verdicts = try await withThrowingTaskGroup(of: SlidingWindowRateLimiter.Verdict.self) { group in
            for _ in 0..<attempts {
                group.addTask {
                    try await limiter.check("shared-ip", on: db, now: now)
                }
            }
            var collected: [SlidingWindowRateLimiter.Verdict] = []
            for try await verdict in group {
                collected.append(verdict)
            }
            return collected
        }

        let allowedCount = verdicts.filter { $0 == .allowed }.count
        XCTAssertEqual(allowedCount, 10, "exactly the configured limit is admitted, no matter the race")
        XCTAssertEqual(verdicts.count, attempts)
    }

    func testStaleBucketsAreSweptFromTheStore() async throws {
        let limiter = SlidingWindowRateLimiter(limit: 5, window: 60)

        _ = try await limiter.check("old-ip", on: app.db, now: bucketStart)
        // Two windows later any check sweeps buckets that no longer affect
        // verdicts, so rotating source addresses can't grow the table.
        _ = try await limiter.check("new-ip", on: app.db, now: bucketStart.addingTimeInterval(180))

        let oldRows = try await windowRows(key: "old-ip")
        XCTAssertEqual(oldRows, 0, "aged-out buckets are deleted")
        let newRows = try await windowRows(key: "new-ip")
        XCTAssertEqual(newRows, 1, "the live bucket stays")
    }

    private func windowRows(key: String) async throws -> Int {
        struct Row: Decodable { var count: Int }
        let sql = try XCTUnwrap(app.db as? any SQLDatabase)
        let row = try await sql.raw("""
        SELECT COUNT(*) AS "count" FROM "auth_rate_windows" WHERE "key" = \(bind: key)
        """).first(decoding: Row.self)
        return try XCTUnwrap(row).count
    }

    // MARK: - HTTP surface

    func testAuthEndpointsReturn429PastTheLimit() async throws {
        // Test requests carry no socket address, so they all share one
        // bucket — which is exactly what this test needs.
        app.authRateLimiter = SlidingWindowRateLimiter(limit: 2, window: 60)

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
        app.authRateLimiter = SlidingWindowRateLimiter(limit: 1, window: 60)

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
        app.authRateLimiter = SlidingWindowRateLimiter(limit: 1, window: 60)

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

    func testCleanupSparesGuestLinkedMidPass() async throws {
        // Regression for #155 (L1 TOCTOU): a guest can link an Apple ID *after*
        // it is read as a candidate but *before* the DELETE runs. The DELETE
        // re-asserts `appleUserID == null`, so the now-recoverable account must
        // survive. The seam commits the link inside that exact window; two
        // controls confirm the pass still reaps ordinary abandoned guests, and
        // the returned count reflects only what was actually deleted.
        let linker = try await seedUser(daysAgo: 60)
        let controlA = try await seedUser(daysAgo: 60)
        let controlB = try await seedUser(daysAgo: 60)

        let removed = try await GuestAccountCleanup.run(on: app.db) {
            // Runs in the candidate-read → delete window: link `linker` to Apple.
            linker.appleUserID = "apple-subject-midpass"
            try await linker.save(on: app.db)
        }

        // The mid-pass link spares `linker`…
        let survivor = try await User.find(linker.requireID(), on: app.db)
        XCTAssertNotNil(survivor, "an account linked mid-pass must not be reaped")
        XCTAssertEqual(survivor?.appleUserID, "apple-subject-midpass")
        // …while the untouched controls are reaped.
        let survivingControlA = try await User.find(controlA.requireID(), on: app.db)
        let survivingControlB = try await User.find(controlB.requireID(), on: app.db)
        XCTAssertNil(survivingControlA, "an ordinary abandoned guest is still reaped")
        XCTAssertNil(survivingControlB, "an ordinary abandoned guest is still reaped")
        XCTAssertEqual(removed, 2, "the spared account must not be counted as deleted")
    }
}
