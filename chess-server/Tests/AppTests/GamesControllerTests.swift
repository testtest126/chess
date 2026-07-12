@testable import App
import XCTVapor
import Fluent
import ChessOnline

final class GamesControllerTests: XCTestCase {
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
        whiteName: String = "White", blackName: String = "Black",
        result: String = "1-0", endReason: String = "checkmate",
        uciMoves: String = "f2f3 e7e5 g2g4 d8h4",
        timeControl: String? = "blitz"
    ) async throws -> GameRecord {
        let record = GameRecord(
            whiteID: whiteID, blackID: blackID,
            whiteName: whiteName, blackName: blackName,
            result: result, endReason: endReason,
            uciMoves: uciMoves, timeControl: timeControl
        )
        try await record.save(on: app.db)
        return record
    }

    // MARK: - GET /games

    func testListReturnsAuthenticatedUsersGames() async throws {
        let alice = try await register(name: "Alice")
        let bob = try await register(name: "Bobby")
        let charlie = try await register(name: "Charlie")

        let game1 = try await seedGame(
            whiteID: alice.userID, blackID: bob.userID,
            whiteName: "Alice", blackName: "Bobby"
        )
        _ = try await seedGame(
            whiteID: bob.userID, blackID: charlie.userID,
            whiteName: "Bobby", blackName: "Charlie"
        )
        let game3 = try await seedGame(
            whiteID: charlie.userID, blackID: alice.userID,
            whiteName: "Charlie", blackName: "Alice",
            result: "0-1", endReason: "resignation"
        )

        try await app.test(.GET, "games", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: alice.accessToken)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let games = try res.content.decode([GameRecordDTO].self, using: decoder)
            XCTAssertEqual(games.count, 2)
            let ids = Set(games.map(\.id))
            XCTAssertTrue(ids.contains(try game1.requireID()))
            XCTAssertTrue(ids.contains(try game3.requireID()))
        })
    }

    func testListReturnsEmptyWhenNoGames() async throws {
        let alice = try await register()

        try await app.test(.GET, "games", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: alice.accessToken)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let games = try res.content.decode([GameRecordDTO].self, using: decoder)
            XCTAssertEqual(games.count, 0)
        })
    }

    func testListRequiresAuthentication() async throws {
        try await app.test(.GET, "games", afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    // MARK: - GET /games/:id

    func testDetailReturnsGameForParticipant() async throws {
        let alice = try await register(name: "Alice")
        let bob = try await register(name: "Bobby")

        let game = try await seedGame(
            whiteID: alice.userID, blackID: bob.userID,
            whiteName: "Alice", blackName: "Bobby",
            uciMoves: "e2e4 e7e5 g1f3"
        )
        let gameID = try game.requireID()

        try await app.test(.GET, "games/\(gameID)", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: alice.accessToken)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let dto = try res.content.decode(GameRecordDTO.self, using: decoder)
            XCTAssertEqual(dto.id, gameID)
            XCTAssertEqual(dto.result, "1-0")
            XCTAssertEqual(dto.uciMoves, "e2e4 e7e5 g1f3")
        })

        // Black can also see the game.
        try await app.test(.GET, "games/\(gameID)", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: bob.accessToken)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
        })
    }

    func testDetailForbidsNonParticipant() async throws {
        let alice = try await register()
        let bob = try await register()
        let charlie = try await register()

        let game = try await seedGame(whiteID: alice.userID, blackID: bob.userID)
        let gameID = try game.requireID()

        try await app.test(.GET, "games/\(gameID)", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: charlie.accessToken)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .forbidden)
        })
    }

    func testDetailReturns404ForMissingGame() async throws {
        let alice = try await register()

        try await app.test(.GET, "games/\(UUID())", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: alice.accessToken)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    func testDetailReturns400ForInvalidID() async throws {
        let alice = try await register()

        try await app.test(.GET, "games/not-a-uuid", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: alice.accessToken)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .badRequest)
        })
    }
}
