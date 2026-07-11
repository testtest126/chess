import Vapor
import Fluent
import Crypto

/// A single-use nonce for Sign in with Apple. The server mints it, the client
/// binds its SHA-256 into the authorization request, Apple echoes that hash in
/// the identity token's `nonce` claim, and the server consumes the row on
/// sign-in — so a captured identity token can't be replayed.
///
/// Only the hash is stored (mirroring refresh tokens): the raw value crosses
/// the wire exactly once, to the requesting client.
final class AppleNonce: Model, @unchecked Sendable {
    static let schema = "apple_nonces"

    /// Nonces are short-lived; sign-in is an interactive flow.
    static let lifetime: TimeInterval = 10 * 60

    @ID(key: .id)
    var id: UUID?

    /// SHA-256 hex of the raw nonce — identical to the value the client sets
    /// on the authorization request and Apple echoes in the token.
    @Field(key: "nonce_hash")
    var nonceHash: String

    @Field(key: "expires_at")
    var expiresAt: Date

    init() {}

    init(nonceHash: String, expiresAt: Date) {
        self.nonceHash = nonceHash
        self.expiresAt = expiresAt
    }

    /// Mints a new nonce, returning the raw value (sent to the client once)
    /// and the persistable model.
    static func generate() -> (raw: String, model: AppleNonce) {
        let raw = Data([UInt8].random(count: 32)).base64URLEncodedString()
        return (raw, AppleNonce(
            nonceHash: hash(raw),
            expiresAt: Date().addingTimeInterval(lifetime)
        ))
    }

    /// SHA-256 hex — the transform the client applies before handing the
    /// nonce to AuthenticationServices.
    static func hash(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
