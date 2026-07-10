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

    func testSignInWithAppleCreatesAccount() async throws {
        let appleUserID = "000001.abc123def456.1234"
        let identityToken = createAppleIdentityToken(
            sub: appleUserID,
            expiry: Date().addingTimeInterval(3600)
        )

        var response: AuthResponse!
        try await app.test(.POST, "auth/apple", beforeRequest: { req in
            let request = AppleSignInRequest(identityToken: identityToken, displayName: "John Doe")
            try req.content.encode(request, as: .json)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            response = try res.content.decode(AuthResponse.self)
        })

        XCTAssertEqual(response.displayName, "John Doe")
        XCTAssertEqual(response.appleLinked, true)
        XCTAssertFalse(response.accessToken.isEmpty)
        XCTAssertFalse(response.refreshToken.isEmpty)

        // Verify the user was created with Apple ID linked
        try await app.test(.GET, "me", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: response.accessToken)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let me = try res.content.decode(UserDTO.self)
            XCTAssertEqual(me.displayName, "John Doe")
        })
    }

    func testSignInWithAppleReturnsExistingAccount() async throws {
        let appleUserID = "000002.abc123def456.1234"
        let identityToken = createAppleIdentityToken(
            sub: appleUserID,
            expiry: Date().addingTimeInterval(3600)
        )

        // First sign-in creates account
        var firstResponse: AuthResponse!
        try await app.test(.POST, "auth/apple", beforeRequest: { req in
            let request = AppleSignInRequest(identityToken: identityToken, displayName: "Jane Doe")
            try req.content.encode(request, as: .json)
        }, afterResponse: { res async throws in
            firstResponse = try res.content.decode(AuthResponse.self)
        })

        // Second sign-in returns same account
        var secondResponse: AuthResponse!
        try await app.test(.POST, "auth/apple", beforeRequest: { req in
            let request = AppleSignInRequest(identityToken: identityToken, displayName: "Different Name")
            try req.content.encode(request, as: .json)
        }, afterResponse: { res async throws in
            secondResponse = try res.content.decode(AuthResponse.self)
        })

        XCTAssertEqual(firstResponse.userID, secondResponse.userID)
        XCTAssertEqual(secondResponse.displayName, "Jane Doe") // Original name preserved
    }

    func testSignInWithAppleRejectsExpiredToken() async throws {
        let appleUserID = "000003.abc123def456.1234"
        let expiredToken = createAppleIdentityToken(
            sub: appleUserID,
            expiry: Date().addingTimeInterval(-3600) // Expired 1 hour ago
        )

        try await app.test(.POST, "auth/apple", beforeRequest: { req in
            let request = AppleSignInRequest(identityToken: expiredToken)
            try req.content.encode(request, as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    private func createAppleIdentityToken(sub: String, expiry: Date) -> String {
        // Create a minimal Apple identity token JWT for testing
        // This would normally be signed by Apple, but for testing we use the app's key
        let payload = AppleIdentityTokenPayload(
            sub: sub,
            exp: ExpirationClaim(value: expiry),
            iss: IssuerClaim(value: "https://appleid.apple.com"),
            aud: AudienceClaim(value: "com.example.chess")
        )

        do {
            // Sign with the test app's JWT key
            let token = try app.jwt.signers.sign(payload)
            return token
        } catch {
            XCTFail("Failed to create test token: \(error)")
            return ""
        }
    }
}
