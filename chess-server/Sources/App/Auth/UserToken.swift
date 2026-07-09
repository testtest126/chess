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

    func verify(using signer: JWTSigner) throws {
        try exp.verifyNotExpired()
    }

    var userID: UUID? { UUID(uuidString: sub.value) }
}

extension Request {
    /// Verifies the bearer token and loads the authenticated user's ID.
    func authenticatedUserID() throws -> UUID {
        let payload = try jwt.verify(as: UserPayload.self)
        guard let id = payload.userID else {
            throw Abort(.unauthorized, reason: "malformed subject claim")
        }
        return id
    }

    func authenticatedUser() async throws -> User {
        let id = try authenticatedUserID()
        guard let user = try await User.find(id, on: db) else {
            throw Abort(.unauthorized, reason: "unknown user")
        }
        return user
    }
}
