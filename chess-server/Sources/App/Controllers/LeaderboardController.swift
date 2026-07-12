import Vapor
import Fluent
import SQLKit
import ChessOnline

struct LeaderboardController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("leaderboard", use: leaderboard)
    }

    /// Top players by rating. Only players who have finished at least one
    /// game appear — fresh guest accounts don't clutter the board.
    @Sendable
    func leaderboard(req: Request) async throws -> [LeaderboardEntry] {
        _ = try await req.authenticatedUserID()

        // Filter to players-with-games in the query, BEFORE the limit:
        // fetching the top 200 by rating first and dropping zero-game guests
        // afterward returns an empty board once 200+ default-rated guests
        // pile up (#145). The JOIN excludes zero-game accounts and the
        // aggregate yields each player's game count in one pass (no N+1).
        guard let sql = req.db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "leaderboard requires a SQL database")
        }

        // id is cast to text so the one decode path works on both Postgres
        // (uuid column) and SQLite (uuid stored as text).
        struct Row: Decodable {
            let id: String
            let displayName: String
            let rating: Int
            let games: Int
        }

        let rows = try await sql.raw("""
        SELECT CAST(u."id" AS text) AS "id",
               u."display_name" AS "displayName",
               u."rating" AS "rating",
               COUNT(g."id") AS "games"
        FROM "users" u
        JOIN "game_records" g ON g."white_id" = u."id" OR g."black_id" = u."id"
        GROUP BY u."id", u."display_name", u."rating", u."created_at"
        ORDER BY u."rating" DESC, u."created_at" ASC
        LIMIT 50
        """).all(decoding: Row.self)

        return rows.compactMap { row in
            guard let id = UUID(uuidString: row.id) else { return nil }
            return LeaderboardEntry(
                id: id,
                displayName: row.displayName,
                rating: row.rating,
                games: row.games
            )
        }
    }
}

extension LeaderboardEntry: @retroactive Content {}
