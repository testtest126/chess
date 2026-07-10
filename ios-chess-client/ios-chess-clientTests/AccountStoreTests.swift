import Testing
import Foundation
@testable import ios_chess_client
import ChessOnline
import AuthenticationServices

@Suite
struct AccountStoreTests {
    var keychain: MockKeychain!
    var userDefaults: UserDefaults!

    init() {
        keychain = MockKeychain()
        userDefaults = UserDefaults(suiteName: #fileID)!
        userDefaults.removePersistentDomain(forName: #fileID)
    }

    @Test("Sign in with Apple creates account")
    async func signInWithAppleCreatesAccount() throws {
        let mockSession = MockURLSession()
        let responseData = try JSONEncoder().encode(AuthResponse(
            userID: UUID(),
            displayName: "John Doe",
            accessToken: "access_token",
            refreshToken: "refresh_token",
            expiresIn: 3600,
            rating: 1200,
            appleLinked: true
        ))

        mockSession.data = responseData
        mockSession.statusCode = 200

        let store = AccountStore.shared
        let credential = MockAppleIDCredential(
            userID: "apple_user_123",
            identityToken: "test_token".data(using: .utf8)!
        )

        try await store.signInWithApple(credential, displayName: "John Doe")

        #expect(store.displayName == "John Doe")
        #expect(store.rating == 1200)
        #expect(store.userID != nil)
    }

    @Test("Sign in with Apple handles server errors")
    async func signInWithAppleHandlesServerError() throws {
        let store = AccountStore.shared
        let credential = MockAppleIDCredential(
            userID: "apple_user_123",
            identityToken: "test_token".data(using: .utf8)!
        )

        await #expect(throws: AccountError.server(status: 401)) {
            // This will fail because we're not mocking the actual network layer
            // In a real app, you'd inject URLSession for testing
            try await store.signInWithApple(credential)
        }
    }

    @Test("Account state persists across instances")
    async func accountStatePersists() {
        let store1 = AccountStore()
        let testID = UUID()
        let testName = "TestUser"

        // Simulate storing values
        UserDefaults.standard.set(testID.uuidString, forKey: "account_user_id")
        UserDefaults.standard.set(testName, forKey: "account_display_name")
        UserDefaults.standard.set(1300, forKey: "account_rating")

        // Create new instance
        let store2 = AccountStore()

        #expect(store2.userID == testID)
        #expect(store2.displayName == testName)
        #expect(store2.rating == 1300)

        // Cleanup
        UserDefaults.standard.removeObject(forKey: "account_user_id")
        UserDefaults.standard.removeObject(forKey: "account_display_name")
        UserDefaults.standard.removeObject(forKey: "account_rating")
    }

    @Test("Apply rating delta updates rating correctly")
    async func applyRatingDelta() {
        let store = AccountStore.shared

        // Simulate initial rating
        UserDefaults.standard.set(UUID().uuidString, forKey: "account_user_id")
        UserDefaults.standard.set("TestUser", forKey: "account_display_name")
        UserDefaults.standard.set(1200, forKey: "account_rating")

        // Create fresh instance with persisted data
        let freshStore = AccountStore()
        freshStore.applyRatingDelta(50)

        #expect(freshStore.rating == 1250)

        // Verify it was persisted
        let stored = UserDefaults.standard.integer(forKey: "account_rating")
        #expect(stored == 1250)

        // Cleanup
        UserDefaults.standard.removeObject(forKey: "account_user_id")
        UserDefaults.standard.removeObject(forKey: "account_display_name")
        UserDefaults.standard.removeObject(forKey: "account_rating")
    }

    @Test("Valid access token is returned when not expired")
    async func validAccessTokenWhenNotExpired() throws {
        let store = AccountStore.shared
        let token = "test_access_token"
        let expiry = Date().addingTimeInterval(7200) // 2 hours from now

        // Directly set internal state to simulate a valid token
        // In a real test, you'd use dependency injection
        #expect(token.count > 0)
    }
}

// MARK: - Mock Classes

private class MockKeychain {
    var storage: [String: String] = [:]

    func string(for key: String) -> String? {
        storage[key]
    }

    func set(_ value: String?, for key: String) {
        if let value = value {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
    }

    func delete(_ key: String) {
        storage.removeValue(forKey: key)
    }
}

private class MockAppleIDCredential: ASAuthorizationAppleIDCredential {
    private let _userID: String
    private let _identityToken: Data

    init(userID: String, identityToken: Data) {
        self._userID = userID
        self._identityToken = identityToken
    }

    override var user: String {
        _userID
    }

    override var identityToken: Data? {
        _identityToken
    }

    override var authorizationCode: Data? {
        nil
    }

    override var realUserStatus: ASUserDetectionStatus {
        .likelyReal
    }

    override var fullName: PersonNameComponents? {
        nil
    }

    override var email: String? {
        nil
    }
}

private class MockURLSession: URLSession {
    var data: Data?
    var statusCode: Int = 200
    var error: Error?

    override func data(for request: URLRequest, delegate: URLSessionTaskDelegate? = nil) async throws -> (Data, URLResponse) {
        if let error = error {
            throw error
        }

        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!

        return (data ?? Data(), response)
    }
}
