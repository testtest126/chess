@testable import App
import XCTVapor
import Fluent
import JWT
import ChessOnline

/// In-app account deletion (#108): DELETE /me must erase the user and every
/// credential, anonymize (not delete) their game records, and make all
/// previously issued tokens — refresh *and* still-unexpired bearers — stop
/// working immediately.
final class AccountDeletionTests: XCTestCase {
    var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
    }

    // MARK: - Helpers

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

    func deleteMe(bearer: String, expecting expected: HTTPStatus = .noContent) async throws {
        try await app.test(.DELETE, "me", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: bearer)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, expected)
        })
    }

    // MARK: - Tests

    func testDeleteRequiresAuthentication() async throws {
        try await app.test(.DELETE, "me", afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
        try await app.test(.DELETE, "me", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: "garbage")
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    func testDeleteRemovesUserAndAllRefreshTokens() async throws {
        let auth = try await register()
        // A second device's credential for the same account: deletion must
        // sweep every token, not just the one presented last.
        let (otherDeviceToken, model) = RefreshToken.generate(for: auth.userID)
        try await model.save(on: app.db)

        try await deleteMe(bearer: auth.accessToken)

        // No user row, no orphaned refresh tokens.
        let users = try await User.query(on: app.db)
            .filter(\.$id == auth.userID)
            .count()
        XCTAssertEqual(users, 0)
        let tokens = try await RefreshToken.query(on: app.db)
            .filter(\.$user.$id == auth.userID)
            .count()
        XCTAssertEqual(tokens, 0, "deletion must not leave orphaned refresh tokens")

        // Neither device's refresh token can mint new credentials.
        for refreshToken in [auth.refreshToken, otherDeviceToken] {
            try await app.test(.POST, "auth/refresh", beforeRequest: { req in
                try req.content.encode(RefreshRequest(refreshToken: refreshToken), as: .json)
            }, afterResponse: { res async in
                XCTAssertEqual(res.status, .unauthorized)
            })
        }
    }

    func testDeletedBearerStopsWorkingImmediately() async throws {
        let auth = try await register()
        try await deleteMe(bearer: auth.accessToken)

        // The JWT is still signature-valid and unexpired (1h lifetime) —
        // every authenticated route must reject it anyway, including the
        // ones that don't otherwise need the user row.
        try await app.test(.GET, "me", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: auth.accessToken)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
        try await app.test(.GET, "games", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: auth.accessToken)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
        try await app.test(.GET, "leaderboard", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: auth.accessToken)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
        try await app.test(.PATCH, "me", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: auth.accessToken)
            try req.content.encode(["displayName": "Ghost"], as: .json)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
        // Repeat deletion is a plain 401, not a second-delete surprise.
        try await deleteMe(bearer: auth.accessToken, expecting: .unauthorized)
    }

    func testDeleteAnonymizesGameRecordsAndKeepsOpponentHistory() async throws {
        let deleter = try await register(name: "Leaving Soon")
        let opponent = try await register(name: "Staying Put")

        let record = GameRecord(
            whiteID: deleter.userID, blackID: opponent.userID,
            whiteName: deleter.displayName, blackName: opponent.displayName,
            result: "0-1", endReason: "checkmate", uciMoves: "f2f3 e7e5 g2g4 d8h4"
        )
        try await record.save(on: app.db)

        try await deleteMe(bearer: deleter.accessToken)

        // The record survives — anonymized on the deleter's side only.
        let found = try await GameRecord.find(record.requireID(), on: app.db)
        let stored = try XCTUnwrap(found)
        XCTAssertEqual(stored.whiteID, AccountDeletion.anonymizedPlayerID)
        XCTAssertEqual(stored.whiteName, AccountDeletion.anonymizedPlayerName)
        XCTAssertEqual(stored.blackID, opponent.userID, "the opponent's side must be untouched")
        XCTAssertEqual(stored.blackName, opponent.displayName)
        XCTAssertEqual(stored.uciMoves, "f2f3 e7e5 g2g4 d8h4", "the game itself is not personal data")

        // The opponent still sees the game in their history and can open it.
        try await app.test(.GET, "games", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: opponent.accessToken)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let games = try res.content.decode([GameRecordDTO].self)
            XCTAssertEqual(games.count, 1)
            XCTAssertEqual(games[0].whiteName, AccountDeletion.anonymizedPlayerName)
        })
        try await app.test(.GET, "games/\(try record.requireID())", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: opponent.accessToken)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
        })

        // Leaderboard integrity: the opponent's game still counts, and the
        // deleted account is gone from the board.
        try await app.test(.GET, "leaderboard", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: opponent.accessToken)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let entries = try res.content.decode([LeaderboardEntry].self)
            XCTAssertEqual(entries.map(\.id), [opponent.userID])
            XCTAssertEqual(entries.first?.games, 1)
        })
    }

    func testDeleteAppleLinkedAccountFreesTheAppleID() async throws {
        // An Apple-linked account exactly as /auth/apple leaves it (the SIWA
        // flow itself is covered in AuthTests; this exercises deletion).
        let user = User(displayName: "Linked User", appleUserID: "apple-subject-erased")
        try await user.save(on: app.db)
        let userID = try user.requireID()
        let (_, refreshModel) = RefreshToken.generate(for: userID)
        try await refreshModel.save(on: app.db)
        let bearer = try await app.jwt.keys.sign(UserPayload(userID: userID))

        try await deleteMe(bearer: bearer)

        // Row, link, and credentials are gone.
        let linked = try await User.query(on: app.db)
            .filter(\.$appleUserID == "apple-subject-erased")
            .count()
        XCTAssertEqual(linked, 0)
        let tokens = try await RefreshToken.query(on: app.db)
            .filter(\.$user.$id == userID)
            .count()
        XCTAssertEqual(tokens, 0)

        // Signing in again with the same Apple ID resolves to a *fresh*
        // account — deletion must not be recoverable through SIWA.
        let resolved = try await AuthController.resolveAppleUser(
            subject: "apple-subject-erased",
            requestedName: nil,
            currentUser: nil,
            on: app.db
        )
        XCTAssertNotEqual(try resolved.requireID(), userID,
                          "a deleted account must not resurrect via Apple sign-in")
    }
}
