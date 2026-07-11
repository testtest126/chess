import Vapor
import JWT

/// The claims the sign-in flow needs from a verified Apple identity token.
struct AppleTokenClaims: Sendable, Equatable {
    /// Apple's stable per-team user ID (`sub`).
    var subject: String
    /// The nonce the client bound into the authorization request, echoed by
    /// Apple in the token. Nil for (hypothetical) tokens minted without one.
    var nonce: String?
}

/// Verifies an Apple identity token and returns its claims. The live
/// implementation checks the RS256 signature against Apple's published JWKS
/// and the audience against the configured application identifier — tests
/// inject a stub instead, because genuine Apple signatures can't be minted
/// offline.
struct AppleTokenVerifier: Sendable {
    var verify: @Sendable (_ identityToken: String, _ req: Request) async throws -> AppleTokenClaims

    static let live = AppleTokenVerifier { identityToken, req in
        // `req.jwt.apple.verify` fetches Apple's JWKS, verifies the signature
        // and standard claims, and checks `aud` against
        // `app.jwt.apple.applicationIdentifier` (the app's bundle ID).
        let identity = try await req.jwt.apple.verify(identityToken)
        return AppleTokenClaims(subject: identity.subject.value, nonce: identity.nonce)
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
