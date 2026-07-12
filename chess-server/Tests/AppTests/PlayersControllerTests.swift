@testable import App
import XCTVapor
import Fluent
import ChessOnline

final class PlayersControllerTests: XCTestCase {
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

    func seedGame(
        whiteID: UUID, blackID: UUID,
        result: String = "1-0", endReason: String = "checkmate"
    ) async throws {
        let record = GameRecord(
            whiteID: whiteID, blackID: blackID,
            whiteName: "W", blackName: "B",
            result: result, endReason: endReason,
            uciMoves: "e2e4 e7e5"
        )
        try await record.save(on: app.db)
    }

    // MARK: - Tests

    func testProfileRequiresAuthentication() async throws {
        try await app.test(.GET, "players/\(UUID())", afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    func testProfileReturns404ForUnknownPlayer() async throws {
        let alice = try await register()

        try await app.test(.GET, "players/\(UUID())", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: alice.accessToken)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    func testProfileReturns400ForInvalidID() async throws {
        let alice = try await register()

        try await app.test(.GET, "players/not-a-uuid", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: alice.accessToken)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    func testProfileAggregatesWinDrawLoss() async throws {
        let alice = try await register(name: "Alice")
        let bob = try await register(name: "Bobby")

        // Alice wins as white.
        try await seedGame(whiteID: alice.userID, blackID: bob.userID, result: "1-0")
        // Alice loses as white.
        try await seedGame(whiteID: alice.userID, blackID: bob.userID, result: "0-1")
        // Alice wins as black.
        try await seedGame(whiteID: bob.userID, blackID: alice.userID, result: "0-1")
        // Draw.
        try await seedGame(whiteID: alice.userID, blackID: bob.userID, result: "1/2-1/2")

        try await app.test(.GET, "players/\(alice.userID)", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: bob.accessToken)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let profile = try res.content.decode(PlayerProfileDTO.self, using: decoder)
            XCTAssertEqual(profile.id, alice.userID)
            XCTAssertEqual(profile.displayName, "Alice")
            XCTAssertEqual(profile.wins, 2)
            XCTAssertEqual(profile.draws, 1)
            XCTAssertEqual(profile.losses, 1)
            XCTAssertEqual(profile.rating, User.initialRating)
        })
    }

    func testProfileReturnsZeroRecordForPlayerWithNoGames() async throws {
        let alice = try await register(name: "Alice")
        let bob = try await register()

        try await app.test(.GET, "players/\(alice.userID)", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: bob.accessToken)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let profile = try res.content.decode(PlayerProfileDTO.self, using: decoder)
            XCTAssertEqual(profile.wins, 0)
            XCTAssertEqual(profile.draws, 0)
            XCTAssertEqual(profile.losses, 0)
        })
    }

    func testProfileIsViewableByAnyAuthenticatedUser() async throws {
        let alice = try await register(name: "Alice")
        let bob = try await register(name: "Bobby")
        let charlie = try await register(name: "Charlie")

        try await seedGame(whiteID: alice.userID, blackID: bob.userID)

        // Charlie (a non-participant) can view Alice's profile.
        try await app.test(.GET, "players/\(alice.userID)", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: charlie.accessToken)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
        })
    }
}
