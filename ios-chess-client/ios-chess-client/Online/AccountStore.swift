import Foundation
import Observation
import ChessOnline

enum AccountError: LocalizedError {
    case server(status: Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .server(let status): return "Server error (\(status))"
        case .invalidResponse: return "Unexpected server response"
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

    private(set) var userID: UUID?
    private(set) var displayName: String?
    private(set) var rating: Int?

    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast

    init() {
        userID = UserDefaults.standard.string(forKey: Self.userIDKey).flatMap(UUID.init(uuidString:))
        displayName = UserDefaults.standard.string(forKey: Self.displayNameKey)
        let storedRating = UserDefaults.standard.integer(forKey: Self.ratingKey)
        rating = storedRating > 0 ? storedRating : nil
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
        return auth.accessToken
    }

    // MARK: - Requests

    private func register() async throws -> AuthResponse {
        try await post("auth/register", body: RegisterRequest())
    }

    private func refresh(with token: String) async throws -> AuthResponse {
        try await post("auth/refresh", body: RefreshRequest(refreshToken: token))
    }

    private func post<Body: Encodable>(_ path: String, body: Body) async throws -> AuthResponse {
        var request = URLRequest(url: ServerConfig.httpBase.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
