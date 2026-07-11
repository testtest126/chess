import Vapor
import Fluent
import ChessOnline

struct UsersController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("me", use: me)
        routes.patch("me", use: rename)
        routes.delete("me", use: deleteMe)
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

    /// In-app account deletion (#108, App Review 5.1.1(v) / GDPR erasure).
    /// Removes the user and their refresh tokens and anonymizes their game
    /// records; see `AccountDeletion` for the policy. Not idempotent by
    /// design: once the row is gone the account's bearers stop
    /// authenticating, so a repeat call is a plain 401.
    @Sendable
    func deleteMe(req: Request) async throws -> HTTPStatus {
        let user = try await req.authenticatedUser()
        try await AccountDeletion.delete(userID: try user.requireID(), on: req.db)
        return .noContent
    }
}
