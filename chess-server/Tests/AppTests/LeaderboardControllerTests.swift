@testable import App
import XCTVapor
import Fluent
import ChessOnline

final class LeaderboardControllerTests: XCTestCase {
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

    func seedGame(whiteID: UUID, blackID: UUID, result: String = "1-0") async throws {
        let record = GameRecord(
            whiteID: whiteID, blackID: blackID,
            whiteName: "W", blackName: "B",
            result: result, endReason: "checkmate",
            uciMoves: "f2f3 e7e5 g2g4 d8h4"
        )
        try await record.save(on: app.db)
    }

    func setRating(_ rating: Int, for auth: AuthResponse) async throws {
        guard let user = try await User.find(auth.userID, on: app.db) else {
            return XCTFail("user not found")
        }
        user.rating = rating
        try await user.save(on: app.db)
    }

    // MARK: - Tests

    func testLeaderboardRequiresAuthentication() async throws {
        try await app.test(.GET, "leaderboard", afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    func testLeaderboardExcludesPlayersWithNoGames() async throws {
        let alice = try await register(name: "Alice")
        let bob = try await register(name: "Bobby")
        let spectator = try await register(name: "Spectator")

        try await seedGame(whiteID: alice.userID, blackID: bob.userID)

        try await app.test(.GET, "leaderboard", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: spectator.accessToken)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let entries = try res.content.decode([LeaderboardEntry].self)
            let ids = entries.map(\.id)
            XCTAssertTrue(ids.contains(alice.userID))
            XCTAssertTrue(ids.contains(bob.userID))
            XCTAssertFalse(ids.contains(spectator.userID))
        })
    }

    func testLeaderboardSortedByRatingDescending() async throws {
        let alice = try await register(name: "Alice")
        let bob = try await register(name: "Bobby")
        let charlie = try await register(name: "Charlie")

        try await setRating(1500, for: alice)
        try await setRating(1300, for: bob)
        try await setRating(1700, for: charlie)

        // All three need at least one game.
        try await seedGame(whiteID: alice.userID, blackID: bob.userID)
        try await seedGame(whiteID: charlie.userID, blackID: alice.userID)

        try await app.test(.GET, "leaderboard", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: alice.accessToken)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let entries = try res.content.decode([LeaderboardEntry].self)
            XCTAssertGreaterThanOrEqual(entries.count, 3)
            let ratings = entries.map(\.rating)
            XCTAssertEqual(ratings, ratings.sorted(by: >))
        })
    }

    func testLeaderboardReturnsEmptyWhenNoGamesPlayed() async throws {
        let alice = try await register()

        try await app.test(.GET, "leaderboard", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: alice.accessToken)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let entries = try res.content.decode([LeaderboardEntry].self)
            XCTAssertEqual(entries.count, 0)
        })
    }

    func testLeaderboardIncludesGameCount() async throws {
        let alice = try await register(name: "Alice")
        let bob = try await register(name: "Bobby")

        try await seedGame(whiteID: alice.userID, blackID: bob.userID)
        try await seedGame(whiteID: bob.userID, blackID: alice.userID, result: "0-1")

        try await app.test(.GET, "leaderboard", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: alice.accessToken)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let entries = try res.content.decode([LeaderboardEntry].self)
            let aliceEntry = entries.first { $0.id == alice.userID }
            XCTAssertNotNil(aliceEntry)
            XCTAssertEqual(aliceEntry?.games, 2)
        })
    }
}
