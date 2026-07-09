import Vapor
import Fluent
import ChessOnline

struct GamesController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let games = routes.grouped("games")
        games.get(use: list)
        games.get(":gameID", use: detail)
    }

    /// The authenticated user's finished games, newest first.
    @Sendable
    func list(req: Request) async throws -> [GameRecordDTO] {
        let userID = try req.authenticatedUserID()
        let records = try await GameRecord.query(on: req.db)
            .group(.or) { group in
                group.filter(\.$whiteID == userID)
                group.filter(\.$blackID == userID)
            }
            .sort(\.$finishedAt, .descending)
            .limit(100)
            .all()
        return try records.map { try $0.dto() }
    }

    @Sendable
    func detail(req: Request) async throws -> GameRecordDTO {
        let userID = try req.authenticatedUserID()
        guard let gameID = req.parameters.get("gameID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "invalid game id")
        }
        guard let record = try await GameRecord.find(gameID, on: req.db) else {
            throw Abort(.notFound)
        }
        // Participants only: game history is not public.
        guard record.whiteID == userID || record.blackID == userID else {
            throw Abort(.forbidden)
        }
        return try record.dto()
    }
}
