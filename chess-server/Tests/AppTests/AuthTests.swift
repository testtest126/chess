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
}
