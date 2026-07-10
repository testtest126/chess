import Foundation
import Observation
import ChessOnline
import AuthenticationServices

enum AccountError: LocalizedError {
    case server(status: Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .server(let status): return String(localized: "Server error (\(status))", comment: "Account error; parameter is the HTTP status code")
        case .invalidResponse: return String(localized: "Unexpected server response", comment: "Account error")
        }
    }
}

/// Owns the guest account: registers on first use, keeps the refresh token in
/// the Keychain, and mints fresh access tokens as needed. Registration is
/// lazy — no account exists until the user first plays online.
@MainActor
@Observable
final class AccountStore {
    static let shared = AccountStore()

    private static let refreshTokenKey = "refresh_token"
    private static let userIDKey = "account_user_id"
    private static let displayNameKey = "account_display_name"
    private static let ratingKey = "account_rating"
    private static let appleLinkedKey = "account_apple_linked"

    private(set) var userID: UUID?
    private(set) var displayName: String?
    private(set) var rating: Int?
    /// Whether the account can be recovered via Sign in with Apple.
    private(set) var appleLinked = false

    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast

    init() {
        userID = UserDefaults.standard.string(forKey: Self.userIDKey).flatMap(UUID.init(uuidString:))
        displayName = UserDefaults.standard.string(forKey: Self.displayNameKey)
        let storedRating = UserDefaults.standard.integer(forKey: Self.ratingKey)
        rating = storedRating > 0 ? storedRating : nil
        appleLinked = UserDefaults.standard.bool(forKey: Self.appleLinkedKey)
    }

    /// Keeps the locally shown rating in sync after a rated game ends.
    func applyRatingDelta(_ delta: Int) {
        guard let current = rating else { return }
        rating = current + delta
        UserDefaults.standard.set(current + delta, forKey: Self.ratingKey)
    }

    /// Returns a usable access token, refreshing or registering as necessary.
    func validAccessToken() async throws -> String {
        // Margin so a token can't expire mid-handshake.
        if let token = accessToken, accessTokenExpiry > Date().addingTimeInterval(60) {
            return token
        }

        if let refreshToken = KeychainStore.string(for: Self.refreshTokenKey) {
            do {
                return try await adopt(refresh(with: refreshToken))
            } catch AccountError.server(let status) where status == 401 {
                // Credential revoked or lost server-side; fall through and
                // start over with a fresh guest account.
                KeychainStore.delete(Self.refreshTokenKey)
            }
        }

        return try await adopt(register())
    }

    private func adopt(_ auth: AuthResponse) -> String {
        userID = auth.userID
        displayName = auth.displayName
        rating = auth.rating
        accessToken = auth.accessToken
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(auth.expiresIn))
        KeychainStore.set(auth.refreshToken, for: Self.refreshTokenKey)
        UserDefaults.standard.set(auth.userID.uuidString, forKey: Self.userIDKey)
        UserDefaults.standard.set(auth.displayName, forKey: Self.displayNameKey)
        if let rating = auth.rating {
            UserDefaults.standard.set(rating, forKey: Self.ratingKey)
        }
        if let linked = auth.appleLinked {
            appleLinked = linked
            UserDefaults.standard.set(linked, forKey: Self.appleLinkedKey)
        }
        return auth.accessToken
    }

    // MARK: - Requests

    /// Renames the account (server validates 3-24 chars). Throws
    /// `AccountError.server(status: 400)` when the name is rejected.
    func rename(to newName: String) async throws {
        let token = try await validAccessToken()
        var request = URLRequest(url: ServerConfig.httpBase.appending(path: "me"))
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["displayName": newName])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AccountError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw AccountError.server(status: http.statusCode)
        }
        let user = try JSONDecoder().decode(UserDTO.self, from: data)
        displayName = user.displayName
        UserDefaults.standard.set(user.displayName, forKey: Self.displayNameKey)
    }

    /// Top players by rating (requires an account; registers one if needed).
    func fetchLeaderboard() async throws -> [LeaderboardEntry] {
        let token = try await validAccessToken()
        var request = URLRequest(url: ServerConfig.httpBase.appending(path: "leaderboard"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AccountError.server(status: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode([LeaderboardEntry].self, from: data)
    }

    private func register() async throws -> AuthResponse {
        try await post("auth/register", body: RegisterRequest())
    }

    private func refresh(with token: String) async throws -> AuthResponse {
        try await post("auth/refresh", body: RefreshRequest(refreshToken: token))
    }

    /// Signs in with an Apple identity credential from AuthenticationServices.
    /// The server resolves the account with recovery first: an account already
    /// linked to this Apple ID is returned (any rating/history restored);
    /// otherwise the current guest account is linked in place — which is why
    /// this request carries our bearer token when we have an account — and
    /// only failing both is a fresh account created.
    func signInWithApple(_ credential: ASAuthorizationAppleIDCredential, displayName: String? = nil) async throws {
        guard let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8)
        else {
            throw AccountError.invalidResponse
        }
        // Never auto-register here: creating a throwaway guest just to link it
        // would defeat recovery on a fresh install.
        let bearer = await existingAccessToken()
        _ = adopt(try await post(
            "auth/apple",
            body: AppleSignInRequest(identityToken: token, displayName: displayName),
            bearer: bearer
        ))
    }

    /// A valid access token if an account already exists (refreshing when
    /// needed), or nil. Unlike `validAccessToken()`, never registers.
    private func existingAccessToken() async -> String? {
        if let token = accessToken, accessTokenExpiry > Date().addingTimeInterval(60) {
            return token
        }
        guard let refreshToken = KeychainStore.string(for: Self.refreshTokenKey) else {
            return nil
        }
        return try? adopt(await refresh(with: refreshToken))
    }

    private func post<Body: Encodable>(_ path: String, body: Body, bearer: String? = nil) async throws -> AuthResponse {
        var request = URLRequest(url: ServerConfig.httpBase.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AccountError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw AccountError.server(status: http.statusCode)
        }
        return try JSONDecoder().decode(AuthResponse.self, from: data)
    }
}
