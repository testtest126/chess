import Vapor
import Fluent
import ChessOnline

struct LeaderboardController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("leaderboard", use: leaderboard)
    }

    /// Top players by rating. Only players who have finished at least one
    /// game appear — fresh guest accounts don't clutter the board.
    @Sendable
    func leaderboard(req: Request) async throws -> [LeaderboardEntry] {
        _ = try req.authenticatedUserID()

        let users = try await User.query(on: req.db)
            .sort(\.$rating, .descending)
            .sort(\.$createdAt, .ascending)
            .limit(200)
            .all()

        var entries: [LeaderboardEntry] = []
        entries.reserveCapacity(50)
        for user in users {
            guard entries.count < 50 else { break }
            let userID = try user.requireID()
            let games = try await GameRecord.query(on: req.db)
                .group(.or) { group in
                    group.filter(\.$whiteID == userID)
                    group.filter(\.$blackID == userID)
                }
                .count()
            guard games > 0 else { continue }
            entries.append(LeaderboardEntry(
                id: userID,
                displayName: user.displayName,
                rating: user.rating,
                games: games
            ))
        }
        return entries
    }
}

extension LeaderboardEntry: @retroactive Content {}
