import Vapor
import Fluent
import ChessOnline

struct PlayersController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("players", ":playerID", use: profile)
    }

    /// A player's public profile: display name, rating, lifetime win/draw/loss
    /// record, and member-since date. Requires a signed-in caller (same policy
    /// as the leaderboard) but is not restricted to the profiled player —
    /// unlike /games/:id, no game contents are exposed here.
    @Sendable
    func profile(req: Request) async throws -> PlayerProfileDTO {
        _ = try await req.authenticatedUserID()

        guard let playerID = req.parameters.get("playerID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "invalid player id")
        }
        guard let user = try await User.find(playerID, on: req.db) else {
            throw Abort(.notFound)
        }

        let records = try await GameRecord.query(on: req.db)
            .group(.or) { group in
                group.filter(\.$whiteID == playerID)
                group.filter(\.$blackID == playerID)
            }
            .all()

        var wins = 0, draws = 0, losses = 0
        for record in records {
            let playedWhite = record.whiteID == playerID
            switch record.result {
            case "1/2-1/2":
                draws += 1
            case "1-0":
                if playedWhite { wins += 1 } else { losses += 1 }
            case "0-1":
                if playedWhite { losses += 1 } else { wins += 1 }
            default:
                break // unfinished/unknown results don't count
            }
        }

        return PlayerProfileDTO(
            id: playerID,
            displayName: user.displayName,
            rating: user.rating,
            wins: wins,
            draws: draws,
            losses: losses,
            memberSince: user.createdAt ?? Date()
        )
    }
}

extension PlayerProfileDTO: @retroactive Content {}
