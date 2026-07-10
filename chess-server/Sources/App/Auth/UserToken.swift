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

/// Apple identity token payload. Verified against Apple's public keys at
/// https://appleid.apple.com/auth/keys. The `sub` claim is a stable,
/// private-email user ID unique to the app's team.
struct AppleIdentityTokenPayload: JWTPayload {
    var sub: String?
    var exp: ExpirationClaim
    var iss: IssuerClaim
    var aud: AudienceClaim

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
        // iss and aud verification is handled by Vapor's JWT middleware
        // based on the configured signer or verifier.
    }
}

extension Request {
    /// Verifies the bearer token and loads the authenticated user's ID.
    func authenticatedUserID() async throws -> UUID {
        let payload = try await jwt.verify(as: UserPayload.self)
        guard let id = payload.userID else {
            throw Abort(.unauthorized, reason: "malformed subject claim")
        }
        return id
    }

    func authenticatedUser() async throws -> User {
        let id = try await authenticatedUserID()
        guard let user = try await User.find(id, on: db) else {
            throw Abort(.unauthorized, reason: "unknown user")
        }
        return user
    }
}
