@testable import App
import XCTVapor
import Fluent
import JWT
import ChessOnline

final class AuthTests: XCTestCase {
    var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
    }

    func register(name: String? = nil) async throws -> AuthResponse {
        var response: AuthResponse!
        try await app.test(.POST, "auth/register", beforeRequest: { req in
            try req.content.encode(RegisterRequest(displayName: name), as: .json)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            response = try res.content.decode(AuthResponse.self)
        })
        return response
    }

    func testRegisterGeneratesGuestAccount() async throws {
        let auth = try await register()
        XCTAssertTrue(auth.displayName.hasPrefix("Guest-"))
        XCTAssertFalse(auth.accessToken.isEmpty)
        XCTAssertFalse(auth.refreshToken.isEmpty)

        // Access token works against an authenticated route.
        try await app.test(.GET, "me", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: auth.accessToken)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let me = try res.content.decode(UserDTO.self)
            XCTAssertEqual(me.id, auth.userID)
        })
    }

    func testRegisterValidatesDisplayName() async throws {
        try await app.test(.POST, "auth/register", beforeRequest: { req in
            try req.content.encode(RegisterRequest(displayName: "x"), as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .badRequest)
        })
        try await app.test(.POST, "auth/register", beforeRequest: { req in
            try req.content.encode(RegisterRequest(displayName: "evil<script>"), as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .badRequest)
        })
        let auth = try await register(name: "Magnus_2")
        XCTAssertEqual(auth.displayName, "Magnus_2")
    }

    func testRefreshRotatesToken() async throws {
        let auth = try await register()

        var refreshed: AuthResponse!
        try await app.test(.POST, "auth/refresh", beforeRequest: { req in
            try req.content.encode(RefreshRequest(refreshToken: auth.refreshToken), as: .json)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            refreshed = try res.content.decode(AuthResponse.self)
        })
        XCTAssertEqual(refreshed.userID, auth.userID)
        XCTAssertNotEqual(refreshed.refreshToken, auth.refreshToken)

        // The old token was consumed and can't be replayed.
        try await app.test(.POST, "auth/refresh", beforeRequest: { req in
            try req.content.encode(RefreshRequest(refreshToken: auth.refreshToken), as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    func testConcurrentRefreshRedeemsTheTokenExactlyOnce() async throws {
        let auth = try await register()
        // Application isn't Sendable; a box lets it cross into the concurrent
        // task closures. Safe here — Vapor routes each test request
        // independently, which is exactly the concurrency under test.
        let box = SendableBox(value: app!)
        let token = auth.refreshToken

        // Fire several simultaneous refreshes of the SAME token. Rotation is
        // atomic (DELETE … RETURNING), so exactly one may redeem it — a
        // replayed stolen token and the real client cannot both mint a session
        // (#147). This is the concurrent race testRefreshRotatesToken can't
        // reach: the old SELECT-then-delete let multiple racers both through.
        let codes = try await withThrowingTaskGroup(of: UInt.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    var code: UInt = 0
                    try await box.value.test(.POST, "auth/refresh", beforeRequest: { req in
                        try req.content.encode(RefreshRequest(refreshToken: token), as: .json)
                    }, afterResponse: { res in
                        code = res.status.code
                    })
                    return code
                }
            }
            var all: [UInt] = []
            for try await code in group { all.append(code) }
            return all
        }

        XCTAssertEqual(codes.filter { $0 == 200 }.count, 1,
                       "exactly one concurrent refresh may redeem the token")
        XCTAssertEqual(codes.filter { $0 == 401 }.count, 7,
                       "every other concurrent refresh is rejected")
    }

    func testProtectedRoutesRejectAnonymous() async throws {
        try await app.test(.GET, "me", afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
        try await app.test(.GET, "games", afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
        try await app.test(.GET, "me", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: "garbage")
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    // MARK: - Sign in with Apple

    //
    // Genuine Apple signatures can't be minted offline, so these tests stub
    // the verifier (the seam the live JWKS implementation plugs into) and
    // exercise everything downstream of it: configuration gating, rejection
    // mapping, and the account-resolution policy.

    /// Tracks the nonce hash each sign-in bound, so the stub verifier can
    /// echo it the way Apple echoes the request nonce in the real token.
    private actor NonceEcho {
        var current: String?
        func set(_ value: String?) { current = value }
    }

    private let nonceEcho = NonceEcho()

    /// Configures SIWA with a stub verifier that accepts `validTokens`, maps
    /// them to Apple subjects, and echoes the request-bound nonce hash —
    /// mirroring how Apple mints real identity tokens.
    private func configureApple(validTokens: [String: String]) {
        app.jwt.apple.applicationIdentifier = "com.test.matemate"
        let echo = nonceEcho
        app.appleTokenVerifier = AppleTokenVerifier { token, _ in
            guard let subject = validTokens[token] else {
                throw Abort(.unauthorized)
            }
            return AppleTokenClaims(subject: subject, nonce: await echo.current)
        }
    }

    /// Mints a nonce via the real endpoint, like the client does.
    private func mintNonce() async throws -> String {
        var raw = ""
        try await app.test(.POST, "auth/apple/nonce", afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            raw = try res.content.decode(AppleNonceResponse.self).nonce
        })
        return raw
    }

    /// Signs in, minting a fresh nonce unless one is supplied. `tokenNonce`
    /// overrides what the stub verifier reports as the token's bound nonce
    /// (defaults to the correct hash, i.e. a well-behaved client).
    private func signInWithApple(
        token: String, displayName: String? = nil, bearer: String? = nil,
        nonce: String?? = nil, tokenNonce: String?? = nil
    ) async throws -> (HTTPStatus, AuthResponse?) {
        let rawNonce: String?
        if case .some(let override) = nonce {
            rawNonce = override
        } else {
            rawNonce = try await mintNonce()
        }
        if case .some(let override) = tokenNonce {
            await nonceEcho.set(override)
        } else {
            await nonceEcho.set(rawNonce.map(AppleNonce.hash))
        }

        var status: HTTPStatus = .internalServerError
        var response: AuthResponse?
        try await app.test(.POST, "auth/apple", beforeRequest: { req in
            if let bearer {
                req.headers.bearerAuthorization = .init(token: bearer)
            }
            try req.content.encode(
                AppleSignInRequest(identityToken: token, displayName: displayName, nonce: rawNonce),
                as: .json
            )
        }, afterResponse: { res async in
            status = res.status
            response = try? res.content.decode(AuthResponse.self)
        })
        return (status, response)
    }

    func testAppleSignInRequiresConfiguration() async throws {
        // No SIWA_APP_ID configured: refuse outright rather than mis-verify.
        let (status, _) = try await signInWithApple(token: "anything")
        XCTAssertEqual(status, .serviceUnavailable)
    }

    func testAppleSignInRejectsInvalidToken() async throws {
        configureApple(validTokens: [:])
        let (status, _) = try await signInWithApple(token: "forged-or-garbage")
        XCTAssertEqual(status, .unauthorized)
    }

    func testAppleSignInCreatesAccountWhenNoGuestIsCalling() async throws {
        configureApple(validTokens: ["token-a": "apple-subject-1"])

        let (status, response) = try await signInWithApple(token: "token-a", displayName: "John Doe")
        XCTAssertEqual(status, .ok)
        let auth = try XCTUnwrap(response)
        XCTAssertEqual(auth.displayName, "John Doe")
        XCTAssertEqual(auth.appleLinked, true)
        XCTAssertFalse(auth.accessToken.isEmpty)
        XCTAssertFalse(auth.refreshToken.isEmpty)
    }

    func testAppleSignInLinksCallingGuestAccount() async throws {
        configureApple(validTokens: ["token-b": "apple-subject-2"])

        // An existing guest signs in with Apple: same account, now linked —
        // rating and history must survive (this is the recovery credential).
        let guest = try await register()
        let (status, response) = try await signInWithApple(token: "token-b", bearer: guest.accessToken)
        XCTAssertEqual(status, .ok)
        let auth = try XCTUnwrap(response)
        XCTAssertEqual(auth.userID, guest.userID, "linking must keep the guest's identity")
        XCTAssertEqual(auth.displayName, guest.displayName)
        XCTAssertEqual(auth.appleLinked, true)
    }

    func testAppleSignInRecoveryBeatsLinking() async throws {
        configureApple(validTokens: ["token-c": "apple-subject-3"])

        // Device 1: guest links the Apple ID.
        let original = try await register()
        _ = try await signInWithApple(token: "token-c", bearer: original.accessToken)

        // Device 2: a different fresh guest signs in with the same Apple ID.
        // Recovery wins — they get the original account back, not a link of
        // the new guest.
        let otherGuest = try await register()
        let (status, response) = try await signInWithApple(token: "token-c", bearer: otherGuest.accessToken)
        XCTAssertEqual(status, .ok)
        XCTAssertEqual(try XCTUnwrap(response).userID, original.userID)
    }

    func testAppleSignInSecondTimeReturnsSameAccount() async throws {
        configureApple(validTokens: ["token-d": "apple-subject-4"])

        let (_, first) = try await signInWithApple(token: "token-d", displayName: "Jane Doe")
        let (_, second) = try await signInWithApple(token: "token-d", displayName: "Different Name")
        XCTAssertEqual(try XCTUnwrap(first).userID, try XCTUnwrap(second).userID)
        // Original name preserved: Apple only sends the name on first auth.
        XCTAssertEqual(try XCTUnwrap(second).displayName, "Jane Doe")
    }

    func testLiveVerifierRejectsStructurallyInvalidToken() async throws {
        // The live verifier (Apple JWKS) fails on malformed input before any
        // network activity — the one live path safely testable offline.
        app.jwt.apple.applicationIdentifier = "com.test.matemate"
        let (status, _) = try await signInWithApple(token: "not-even-a-jwt")
        XCTAssertEqual(status, .unauthorized)
    }

    func testAppleSignInRefusesToRelinkToDifferentAppleID() async throws {
        // Takeover guard: a valid bearer must not be able to rebind an
        // already-linked account to a different Apple ID (which would lock
        // the real owner's Apple sign-in out of recovery).
        configureApple(validTokens: ["token-x": "apple-subject-x", "token-y": "apple-subject-y"])

        let guest = try await register()
        let (linkStatus, _) = try await signInWithApple(token: "token-x", bearer: guest.accessToken)
        XCTAssertEqual(linkStatus, .ok)

        let (rebindStatus, _) = try await signInWithApple(token: "token-y", bearer: guest.accessToken)
        XCTAssertEqual(rebindStatus, .conflict)

        // The original binding is intact: subject X still recovers the account.
        let (recoverStatus, recovered) = try await signInWithApple(token: "token-x")
        XCTAssertEqual(recoverStatus, .ok)
        XCTAssertEqual(try XCTUnwrap(recovered).userID, guest.userID)

        // Re-presenting the already-linked subject with the bearer stays fine.
        let (idempotentStatus, _) = try await signInWithApple(token: "token-x", bearer: guest.accessToken)
        XCTAssertEqual(idempotentStatus, .ok)
    }

    func testAppleSignInRejectsInvalidBearerInsteadOfCreatingAccount() async throws {
        // A presented-but-invalid bearer must 401, not silently demote the
        // request to "anonymous" — that would bind the guest's Apple ID to a
        // fresh empty account and strand their history.
        configureApple(validTokens: ["token-z": "apple-subject-z"])

        let (status, _) = try await signInWithApple(token: "token-z", bearer: "expired-or-garbage-bearer")
        XCTAssertEqual(status, .unauthorized)

        // Nothing was created or linked: the subject still recovers nothing
        // (fresh sign-in without a bearer creates the account only now).
        let (freshStatus, fresh) = try await signInWithApple(token: "token-z")
        XCTAssertEqual(freshStatus, .ok)
        XCTAssertEqual(try XCTUnwrap(fresh).appleLinked, true)
    }

    func testLiveVerifierRejectsTokenSignedWithOwnServerKey() async throws {
        // Regression test for the incident that motivated this rework: a
        // WELL-FORMED JWT signed with the server's own HMAC key — accepted by
        // the original implementation — must be rejected by the live Apple
        // verifier (kid mismatch / unreachable JWKS both reject, so this is
        // deterministic offline).
        app.jwt.apple.applicationIdentifier = "com.test.matemate"

        struct ForgedAppleClaims: JWTPayload {
            var sub: SubjectClaim
            var exp: ExpirationClaim
            var iss: IssuerClaim
            var aud: AudienceClaim
            func verify(using algorithm: some JWTAlgorithm) async throws {}
        }
        let forged = try await app.jwt.keys.sign(ForgedAppleClaims(
            sub: .init(value: "attacker-chosen-subject"),
            exp: .init(value: Date().addingTimeInterval(3600)),
            iss: .init(value: "https://appleid.apple.com"),
            aud: .init(value: "com.test.matemate")
        ))

        let (status, _) = try await signInWithApple(token: forged)
        XCTAssertEqual(status, .unauthorized, "a token signed with our own key must never authenticate as Apple")
    }

    // MARK: - Nonce replay protection (#53)

    func testAppleSignInRequiresNonce() async throws {
        configureApple(validTokens: ["token-n0": "apple-subject-n0"])
        let (status, _) = try await signInWithApple(token: "token-n0", nonce: .some(nil))
        XCTAssertEqual(status, .badRequest, "sign-in without a nonce must be refused")
    }

    func testAppleSignInRejectsUnknownNonce() async throws {
        configureApple(validTokens: ["token-n1": "apple-subject-n1"])
        // A nonce the server never minted.
        let (status, _) = try await signInWithApple(token: "token-n1", nonce: .some("made-up-nonce"))
        XCTAssertEqual(status, .unauthorized)
    }

    func testAppleSignInNonceIsSingleUse() async throws {
        configureApple(validTokens: ["token-n2": "apple-subject-n2"])

        let raw = try await mintNonce()
        let (first, _) = try await signInWithApple(token: "token-n2", nonce: .some(raw))
        XCTAssertEqual(first, .ok)

        // Replaying the identical request — same token, same nonce — fails:
        // the nonce was consumed. This is the replay attack itself.
        let (replay, _) = try await signInWithApple(token: "token-n2", nonce: .some(raw))
        XCTAssertEqual(replay, .unauthorized, "a consumed nonce must never authenticate again")
    }

    func testAppleSignInRejectsTokenBoundToDifferentNonce() async throws {
        configureApple(validTokens: ["token-n3": "apple-subject-n3"])
        // The request presents a validly minted nonce, but the identity token
        // was bound to something else (stolen from another session).
        let (status, _) = try await signInWithApple(
            token: "token-n3",
            tokenNonce: .some(AppleNonce.hash("some-other-session-nonce"))
        )
        XCTAssertEqual(status, .unauthorized, "token nonce must match the presented nonce")
    }

    func testFailedSignInStillBurnsTheNonce() async throws {
        configureApple(validTokens: [:]) // every token rejected

        let raw = try await mintNonce()
        let (bad, _) = try await signInWithApple(token: "rejected-token", nonce: .some(raw))
        XCTAssertEqual(bad, .unauthorized)

        // The nonce died with the failed attempt.
        configureApple(validTokens: ["token-n4": "apple-subject-n4"])
        let (reuse, _) = try await signInWithApple(token: "token-n4", nonce: .some(raw))
        XCTAssertEqual(reuse, .unauthorized, "a nonce burned by a failed attempt must stay burned")
    }

    func testNonceConsumptionIsAtomicAndExpiryAware() async throws {
        // Fresh nonce: consumable exactly once (single DELETE..RETURNING —
        // no SELECT-then-DELETE TOCTOU window).
        let (raw, model) = AppleNonce.generate()
        try await model.save(on: app.db)
        let hash = AppleNonce.hash(raw)
        let first = try await AuthController.consumeNonce(hash: hash, on: app.db)
        XCTAssertTrue(first)
        let second = try await AuthController.consumeNonce(hash: hash, on: app.db)
        XCTAssertFalse(second, "a consumed nonce must never be consumable again")

        // Expired nonce: never consumable, and left for the sweeper.
        let expired = AppleNonce(nonceHash: AppleNonce.hash("old"), expiresAt: Date(timeIntervalSinceNow: -60))
        try await expired.save(on: app.db)
        let expiredResult = try await AuthController.consumeNonce(hash: AppleNonce.hash("old"), on: app.db)
        XCTAssertFalse(expiredResult, "expired nonces must not authenticate")
    }

    // MARK: - First-link race (#53)

    func testFirstLinkRaceLoserGetsWinnersAccount() async throws {
        // Simulate the loser's position deterministically: the winner linked
        // `subject` after the loser's recover-query missed, so the loser's
        // save trips the partial unique index. The helper must resolve to the
        // winner's account instead of surfacing a 500.
        let winner = User(displayName: "Winner", appleUserID: "raced-subject")
        try await winner.save(on: app.db)

        let loser = User(displayName: "Loser", appleUserID: "raced-subject")
        let resolved = try await AuthController.savedResolvingLinkRace(
            loser, subject: "raced-subject", on: app.db
        )
        XCTAssertEqual(try resolved.requireID(), try winner.requireID())

        // Exactly one account holds the link.
        let holders = try await User.query(on: app.db)
            .filter(\.$appleUserID == "raced-subject")
            .count()
        XCTAssertEqual(holders, 1)
    }
}

/// Carries a non-Sendable value into concurrent task closures for the
/// refresh-race test.
private struct SendableBox<T>: @unchecked Sendable {
    let value: T
}
