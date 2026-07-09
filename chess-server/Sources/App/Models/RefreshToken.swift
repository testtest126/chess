import Vapor
import Fluent
import Crypto

/// A long-lived credential exchanged for fresh access tokens. Only the SHA-256
/// digest is stored; tokens rotate on every successful refresh.
final class RefreshToken: Model, @unchecked Sendable {
    static let schema = "refresh_tokens"

    static let lifetime: TimeInterval = 90 * 24 * 3600 // 90 days

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "token_hash")
    var tokenHash: String

    @Field(key: "expires_at")
    var expiresAt: Date

    init() {}

    init(userID: UUID, tokenHash: String, expiresAt: Date) {
        self.$user.id = userID
        self.tokenHash = tokenHash
        self.expiresAt = expiresAt
    }

    /// Generates a new opaque token, returning the plaintext (sent to the
    /// client exactly once) and the persistable model.
    static func generate(for userID: UUID) -> (plaintext: String, model: RefreshToken) {
        let bytes = [UInt8].random(count: 32)
        let plaintext = Data(bytes).base64URLEncodedString()
        let model = RefreshToken(
            userID: userID,
            tokenHash: hash(plaintext),
            expiresAt: Date().addingTimeInterval(lifetime)
        )
        return (plaintext, model)
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
