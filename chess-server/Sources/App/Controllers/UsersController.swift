import Vapor
import Fluent
import ChessOnline

struct UsersController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("me", use: me)
        routes.patch("me", use: rename)
    }

    @Sendable
    func me(req: Request) async throws -> UserDTO {
        let user = try await req.authenticatedUser()
        return UserDTO(id: try user.requireID(), displayName: user.displayName, rating: user.rating)
    }

    @Sendable
    func rename(req: Request) async throws -> UserDTO {
        struct RenameRequest: Content {
            var displayName: String
        }
        let user = try await req.authenticatedUser()
        let body = try req.content.decode(RenameRequest.self, as: .json)
        user.displayName = try User.validateDisplayName(body.displayName)
        try await user.save(on: req.db)
        return UserDTO(id: try user.requireID(), displayName: user.displayName, rating: user.rating)
    }
}
