import Vapor
import Fluent
import JWT
import ChessOnline

struct AuthController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let auth = routes.grouped("auth")
        auth.post("register", use: register)
        auth.post("refresh", use: refresh)
    }

    /// Creates a guest account and returns its first token pair. The refresh
    /// token is the account's only credential — the client keeps it in the
    /// Keychain and can never recover the account without it.
    @Sendable
    func register(req: Request) async throws -> AuthResponse {
        let body = try req.content.decode(RegisterRequest.self, as: .json)
        let name: String
        if let requested = body.displayName, !requested.isEmpty {
            name = try User.validateDisplayName(requested)
        } else {
            name = User.generatedGuestName()
        }

        let user = User(displayName: name)
        try await user.save(on: req.db)
        return try await issueTokens(for: user, on: req)
    }

    /// Exchanges a refresh token for a new access token, rotating the refresh
    /// token: the presented token is consumed whether or not it had expired.
    @Sendable
    func refresh(req: Request) async throws -> AuthResponse {
        let body = try req.content.decode(RefreshRequest.self, as: .json)
        let digest = RefreshToken.hash(body.refreshToken)

        guard let stored = try await RefreshToken.query(on: req.db)
            .filter(\.$tokenHash == digest)
            .first()
        else {
            throw Abort(.unauthorized, reason: "invalid refresh token")
        }

        try await stored.delete(on: req.db)
        guard stored.expiresAt > Date() else {
            throw Abort(.unauthorized, reason: "refresh token expired")
        }
        guard let user = try await User.find(stored.$user.id, on: req.db) else {
            throw Abort(.unauthorized, reason: "unknown user")
        }
        return try await issueTokens(for: user, on: req)
    }

    private func issueTokens(for user: User, on req: Request) async throws -> AuthResponse {
        let userID = try user.requireID()
        let (plaintext, model) = RefreshToken.generate(for: userID)
        try await model.save(on: req.db)

        let accessToken = try req.jwt.sign(UserPayload(userID: userID))
        return AuthResponse(
            userID: userID,
            displayName: user.displayName,
            accessToken: accessToken,
            refreshToken: plaintext,
            expiresIn: Int(UserPayload.lifetime),
            rating: user.rating
        )
    }
}

extension AuthResponse: @retroactive Content {}
extension UserDTO: @retroactive Content {}
extension GameRecordDTO: @retroactive Content {}
