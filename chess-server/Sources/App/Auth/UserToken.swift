import Vapor
import JWT

/// Access-token payload. Short-lived; refreshed via the rotating refresh token.
struct UserPayload: JWTPayload {
    static let lifetime: TimeInterval = 3600 // 1 hour

    var sub: SubjectClaim
    var exp: ExpirationClaim

    init(userID: UUID) {
        self.sub = SubjectClaim(value: userID.uuidString)
        self.exp = ExpirationClaim(value: Date().addingTimeInterval(Self.lifetime))
    }

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
    }

    var userID: UUID? { UUID(uuidString: sub.value) }
}

extension Request {
    /// Verifies the bearer token, confirms the account still exists, and
    /// returns its ID. The existence check is deliberate: access tokens are
    /// stateless JWTs with a one-hour life, and account deletion (#108) must
    /// invalidate them immediately — a signature check alone would let a
    /// deleted account keep using /games, /leaderboard, and /play until the
    /// token expired.
    func authenticatedUserID() async throws -> UUID {
        try await authenticatedUser().requireID()
    }

    /// Verifies the bearer token and loads the authenticated user.
    func authenticatedUser() async throws -> User {
        let payload = try await jwt.verify(as: UserPayload.self)
        guard let id = payload.userID else {
            throw Abort(.unauthorized, reason: "malformed subject claim")
        }
        guard let user = try await User.find(id, on: db) else {
            throw Abort(.unauthorized, reason: "unknown user")
        }
        return user
    }
}
