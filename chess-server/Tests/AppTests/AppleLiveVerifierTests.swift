@testable import App
import XCTVapor
import JWT
import Fluent
import ChessOnline

/// Tests for POST /auth/apple through the LIVE verifier path.
///
/// The fake-verifier tests in AuthTests cover account resolution; these cover
/// what the fake can't: `AppleTokenVerifier.live` itself. A locally generated
/// key stands in for Apple's — its public half is served from a loopback JWKS
/// endpoint via `app.jwt.apple.jwksEndpoint` — so the exact production
/// verification path (signature, expiry, issuer, audience) runs against keys
/// the tests control, and tokens that key didn't sign must be refused.
///
/// Refs #53 (SIWA hardening) / #56 (open security issue).
final class AppleLiveVerifierTests: XCTestCase {
    var app: Application!
    /// Loopback server publishing the test JWKS, as appleid.apple.com does.
    var jwksServer: Application!
    /// Signs identity tokens; stands in for Apple's private key.
    var appleKey: ES256PrivateKey!
    let appleKeyID: JWKIdentifier = "test-apple-key"
    let audience = "com.test.matemate"

    override func setUp() async throws {
        appleKey = ES256PrivateKey()
        let coordinates = try XCTUnwrap(appleKey.publicKey.parameters)
        let jwks = """
        {"keys": [{"kty": "EC", "crv": "P-256", "alg": "ES256", "use": "sig", \
        "kid": "\(appleKeyID.string)", "x": "\(coordinates.x)", "y": "\(coordinates.y)"}]}
        """

        jwksServer = try await Application.make(.testing)
        jwksServer.http.server.configuration.hostname = "127.0.0.1"
        jwksServer.http.server.configuration.port = 0
        jwksServer.get("auth", "keys") { _ in
            Response(
                status: .ok,
                headers: ["content-type": "application/json"],
                body: .init(string: jwks)
            )
        }
        jwksServer.environment.arguments = ["serve"]
        try await jwksServer.startup()
        let port = try XCTUnwrap(jwksServer.http.server.shared.localAddress?.port)

        app = try await Application.make(.testing)
        try await configure(app)
        // No appleTokenVerifier override: requests exercise `.live`.
        app.jwt.apple.jwksEndpoint = URI(string: "http://127.0.0.1:\(port)/auth/keys")
        app.jwt.apple.applicationIdentifier = audience
    }

    override func tearDown() async throws {
        if let app { try await app.asyncShutdown() }
        if let jwksServer { try await jwksServer.asyncShutdown() }
        app = nil
        jwksServer = nil
        appleKey = nil
    }

    // MARK: - Accepting Apple's tokens

    func testAcceptsGenuinelySignedTokenAndLinksAccount() async throws {
        let sub = "000001.live.0001"
        let auth = try await signIn(sub: sub, displayName: "Anna Appleseed")

        XCTAssertEqual(auth.displayName, "Anna Appleseed")
        XCTAssertEqual(auth.appleLinked, true)
        XCTAssertFalse(auth.accessToken.isEmpty)
        let linked = try await userCount(appleUserID: sub)
        XCTAssertEqual(linked, 1)
    }

    func testInvalidRequestedNameFallsBackToGuestName() async throws {
        // Apple only shares the name once; a policy-violating one must not
        // fail signup — the account is created with a generated name instead.
        let auth = try await signIn(sub: "000002.live.0002", displayName: "x")
        XCTAssertTrue(auth.displayName.hasPrefix("Guest-"))
        XCTAssertEqual(auth.appleLinked, true)
    }

    func testRepeatSignInReturnsExistingAccount() async throws {
        let sub = "000003.live.0003"
        // Apple mints a fresh token per authorization; the name is only
        // honored while the account is being created.
        let first = try await signIn(sub: sub, displayName: "Original Name")
        let second = try await signIn(sub: sub, displayName: "Different Name")

        XCTAssertEqual(second.userID, first.userID)
        XCTAssertEqual(second.displayName, "Original Name")
        let linked = try await userCount(appleUserID: sub)
        XCTAssertEqual(linked, 1)
    }

    // MARK: - Refusing everything else

    func testRejectsTokenSignedByUnknownKey() async throws {
        // Correct claims — but signed by a key Apple never published, even
        // claiming the genuine key's ID.
        let sub = "000004.live.0004"
        let rogue = JWTKeyCollection()
        await rogue.add(ecdsa: ES256PrivateKey(), kid: appleKeyID)
        let forged = try await rogue.sign(identity(sub: sub), kid: appleKeyID)

        try await expectRejection(of: forged)
        let created = try await userCount(appleUserID: sub)
        XCTAssertEqual(created, 0)
    }

    func testRejectsTokenSignedWithServerJWTSecret() async throws {
        // The PR #50 incident, replayed against a REACHABLE JWKS: a token
        // minted with the server's own HMAC key must lose even when Apple's
        // (stand-in) keys are available, not only when the fetch fails.
        let selfIssued = JWTKeyCollection()
        await selfIssued.add(
            hmac: HMACKey(from: "insecure-development-key-do-not-deploy"),
            digestAlgorithm: .sha256
        )
        let forged = try await selfIssued.sign(identity(sub: "000005.live.0005"))

        try await expectRejection(of: forged)
    }

    func testRejectsTamperedPayload() async throws {
        // Re-target a genuine token to another Apple user ID: the signature
        // no longer matches.
        let genuine = try await appleSigned(identity(sub: "000006.live.0006"))
        var parts = genuine.components(separatedBy: ".")
        let claims = try XCTUnwrap(base64URLDecode(parts[1]))
        let tampered = String(decoding: claims, as: UTF8.self)
            .replacingOccurrences(of: "000006.live.0006", with: "000006.live.9999")
        parts[1] = base64URLEncode(Data(tampered.utf8))

        try await expectRejection(of: parts.joined(separator: "."))
        let created = try await userCount(appleUserID: "000006.live.9999")
        XCTAssertEqual(created, 0)
    }

    func testRejectsUnsignedToken() async throws {
        // alg "none" with an empty signature.
        let header = base64URLEncode(Data(#"{"alg":"none","typ":"JWT"}"#.utf8))
        let claims = base64URLEncode(try JSONEncoder().encode(identity(sub: "000007.live.0007")))
        try await expectRejection(of: "\(header).\(claims).")
    }

    func testRejectsExpiredToken() async throws {
        let stale = try await appleSigned(identity(sub: "000008.live.0008", expiresIn: -600))
        try await expectRejection(of: stale)
    }

    func testRejectsWrongAudience() async throws {
        // A genuine Apple token minted for some other app must not sign in here.
        let other = try await appleSigned(identity(sub: "000009.live.0009", audience: "com.other.app"))
        try await expectRejection(of: other)
    }

    func testRejectsWrongIssuer() async throws {
        let phony = try await appleSigned(identity(sub: "000010.live.0010", issuer: "https://evil.example.com"))
        try await expectRejection(of: phony)
    }

    func testRejectsGenuineTokenNotBoundToTheNonce() async throws {
        // Signed by the real key, every standard claim valid — but minted
        // without our nonce hash (e.g. replayed from a different session).
        // The binding check must refuse it even though the signature verifies.
        let sub = "000011.live.0011"
        try await expectRejection(of: appleSigned(identity(sub: sub)))
        let created = try await userCount(appleUserID: sub)
        XCTAssertEqual(created, 0)
    }

    // MARK: - Helpers

    /// The claims in an Apple identity token, as Apple would mint them.
    private struct IdentityToken: JWTPayload {
        let iss: IssuerClaim
        let aud: AudienceClaim
        let exp: ExpirationClaim
        let iat: IssuedAtClaim
        let sub: SubjectClaim
        /// Apple echoes the nonce hash the client bound into the
        /// authorization request; absent when no nonce was bound.
        let nonce: String?

        func verify(using _: some JWTAlgorithm) throws {}
    }

    /// Builds identity-token claims. Defaults describe a valid token for our
    /// app; overrides produce the invalid variants individual tests need.
    private func identity(
        sub: String,
        audience: String? = nil,
        issuer: String = "https://appleid.apple.com",
        expiresIn: TimeInterval = 600,
        nonce: String? = nil
    ) -> IdentityToken {
        IdentityToken(
            iss: .init(value: issuer),
            aud: .init(value: audience ?? self.audience),
            exp: .init(value: Date().addingTimeInterval(expiresIn)),
            iat: .init(value: Date()),
            sub: .init(value: sub),
            nonce: nonce
        )
    }

    /// Mints a nonce via the real endpoint, like the client does.
    private func mintNonce() async throws -> String {
        var raw = ""
        try await app.test(.POST, "auth/apple/nonce", afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            raw = try res.content.decode(AppleNonceResponse.self).nonce
        })
        return raw
    }

    /// Signs claims with the JWKS-published key, the way Apple would.
    private func appleSigned(_ payload: IdentityToken) async throws -> String {
        let keys = JWTKeyCollection()
        await keys.add(ecdsa: appleKey, kid: appleKeyID)
        return try await keys.sign(payload, kid: appleKeyID)
    }

    /// Runs the full client flow: mint a nonce, get a token bound to its
    /// hash, sign in presenting the raw nonce — and expect success.
    private func signIn(sub: String, displayName: String? = nil) async throws -> AuthResponse {
        let raw = try await mintNonce()
        let token = try await appleSigned(identity(sub: sub, nonce: AppleNonce.hash(raw)))
        var response: AuthResponse!
        try await app.test(.POST, "auth/apple", beforeRequest: { req in
            try req.content.encode(
                AppleSignInRequest(identityToken: token, displayName: displayName, nonce: raw),
                as: .json
            )
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            response = try res.content.decode(AuthResponse.self)
        })
        return response
    }

    /// POSTs the token to /auth/apple and expects it to be refused. The
    /// request itself carries a freshly minted nonce, so rejection comes from
    /// the token being bad — not from the replay guard short-circuiting.
    private func expectRejection(
        of token: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let raw = try await mintNonce()
        try await app.test(.POST, "auth/apple", beforeRequest: { req in
            try req.content.encode(
                AppleSignInRequest(identityToken: token, nonce: raw), as: .json
            )
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized, file: file, line: line)
        })
    }

    private func userCount(appleUserID: String) async throws -> Int {
        try await User.query(on: app.db).filter(\.$appleUserID == appleUserID).count()
    }

    private func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
