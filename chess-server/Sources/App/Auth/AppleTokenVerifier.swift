import Vapor
import JWT

/// Verifies an Apple identity token and returns its stable subject (Apple's
/// per-team user ID). The live implementation checks the RS256 signature
/// against Apple's published JWKS and the audience against the configured
/// application identifier — tests inject a stub instead, because genuine
/// Apple signatures can't be minted offline.
struct AppleTokenVerifier: Sendable {
    var verify: @Sendable (_ identityToken: String, _ req: Request) async throws -> String

    static let live = AppleTokenVerifier { identityToken, req in
        // `req.jwt.apple.verify` fetches Apple's JWKS, verifies the signature
        // and standard claims, and checks `aud` against
        // `app.jwt.apple.applicationIdentifier` (the app's bundle ID).
        let identity = try await req.jwt.apple.verify(identityToken)
        return identity.subject.value
    }
}

extension Application {
    private struct AppleTokenVerifierKey: StorageKey {
        typealias Value = AppleTokenVerifier
    }

    var appleTokenVerifier: AppleTokenVerifier {
        get { storage[AppleTokenVerifierKey.self] ?? .live }
        set { storage[AppleTokenVerifierKey.self] = newValue }
    }
}
