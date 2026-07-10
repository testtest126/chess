@testable import App
import XCTVapor
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

    /// Configures SIWA with a stub verifier that accepts `validTokens` and
    /// maps them to Apple subjects; everything else is rejected.
    private func configureApple(validTokens: [String: String]) {
        app.jwt.apple.applicationIdentifier = "com.test.matemate"
        app.appleTokenVerifier = AppleTokenVerifier { token, _ in
            guard let subject = validTokens[token] else {
                throw Abort(.unauthorized)
            }
            return subject
        }
    }

    private func signInWithApple(
        token: String, displayName: String? = nil, bearer: String? = nil
    ) async throws -> (HTTPStatus, AuthResponse?) {
        var status: HTTPStatus = .internalServerError
        var response: AuthResponse?
        try await app.test(.POST, "auth/apple", beforeRequest: { req in
            if let bearer {
                req.headers.bearerAuthorization = .init(token: bearer)
            }
            try req.content.encode(AppleSignInRequest(identityToken: token, displayName: displayName), as: .json)
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
}
