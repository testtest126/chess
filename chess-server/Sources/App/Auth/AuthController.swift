import Vapor
import Fluent
import JWT
import ChessOnline

struct AuthController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let auth = routes.grouped("auth")
        auth.post("register", use: register)
        auth.post("refresh", use: refresh)
        auth.post("apple", use: signInWithApple)
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

    /// Sign in with Apple. Verifies the identity token against Apple's JWKS
    /// (never our own keys, and never by decoding without verification), then
    /// resolves an account with recovery taking precedence.
    @Sendable
    func signInWithApple(req: Request) async throws -> AuthResponse {
        // Refuse rather than mis-verify when the audience isn't configured.
        guard req.application.jwt.apple.applicationIdentifier != nil else {
            throw Abort(.serviceUnavailable,
                        reason: "Sign in with Apple is not configured on this server (set SIWA_APP_ID)")
        }
        let body = try req.content.decode(AppleSignInRequest.self, as: .json)

        let subject: String
        do {
            subject = try await req.application.appleTokenVerifier.verify(body.identityToken, req)
        } catch {
            throw Abort(.unauthorized, reason: "invalid Apple identity token")
        }

        // A presented bearer must be valid: silently treating an expired or
        // forged bearer as "anonymous" would turn a guest's linking attempt
        // into a fresh account permanently bound to their Apple ID,
        // stranding their history.
        let currentUser: User?
        if req.headers.bearerAuthorization != nil {
            currentUser = try await req.authenticatedUser()
        } else {
            currentUser = nil
        }

        let user = try await Self.resolveAppleUser(
            subject: subject,
            requestedName: body.displayName,
            currentUser: currentUser,
            on: req.db
        )
        return try await issueTokens(for: user, on: req)
    }

    /// Account-resolution policy, factored out for testing:
    /// 1. An account already linked to this Apple ID always wins — signing in
    ///    is recovery, even when a different guest session is calling.
    /// 2. Otherwise the calling guest account (if any) gets linked in place,
    ///    keeping its rating and history.
    /// 3. Otherwise a fresh account is created.
    static func resolveAppleUser(
        subject: String,
        requestedName: String?,
        currentUser: User?,
        on db: Database
    ) async throws -> User {
        if let linked = try await User.query(on: db)
            .filter(\.$appleUserID == subject)
            .first() {
            return linked
        }

        if let currentUser {
            // Never overwrite an existing link: a stolen bearer must not be
            // able to rebind the account to the attacker's Apple ID (which
            // would lock the victim's own Apple sign-in out of recovery).
            guard currentUser.appleUserID == nil || currentUser.appleUserID == subject else {
                throw Abort(.conflict, reason: "account is already linked to a different Apple ID")
            }
            currentUser.appleUserID = subject
            try await currentUser.save(on: db)
            return currentUser
        }

        // Apple only shares the name on first authorization; fall back to a
        // guest name rather than failing signup over an invalid one.
        let name = requestedName.flatMap { try? User.validateDisplayName($0) }
            ?? User.generatedGuestName()
        let user = User(displayName: name, appleUserID: subject)
        try await user.save(on: db)
        return user
    }

    private func issueTokens(for user: User, on req: Request) async throws -> AuthResponse {
        let userID = try user.requireID()
        let (plaintext, model) = RefreshToken.generate(for: userID)
        try await model.save(on: req.db)

        let accessToken = try await req.jwt.sign(UserPayload(userID: userID))
        return AuthResponse(
            userID: userID,
            displayName: user.displayName,
            accessToken: accessToken,
            refreshToken: plaintext,
            expiresIn: Int(UserPayload.lifetime),
            rating: user.rating,
            appleLinked: user.appleUserID != nil
        )
    }
}

extension AuthResponse: @retroactive Content {}
extension UserDTO: @retroactive Content {}
extension GameRecordDTO: @retroactive Content {}
