import Vapor
import Fluent

final class User: Model, Content, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "display_name")
    var displayName: String

    /// Elo rating for online play.
    @Field(key: "rating")
    var rating: Int

    /// Apple's stable per-team user identifier, set once the account is
    /// linked via Sign in with Apple. The account's recovery credential.
    @OptionalField(key: "apple_user_id")
    var appleUserID: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    static let initialRating = 1200

    init() {}

    init(id: UUID? = nil, displayName: String, rating: Int = User.initialRating, appleUserID: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.rating = rating
        self.appleUserID = appleUserID
    }
}

/// Standard Elo with K=32.
enum Elo {
    static let kFactor = 32.0

    /// Rating change for a player scoring `score` (1 win, 0.5 draw, 0 loss)
    /// against an opponent. Positive means the player gains points.
    static func delta(rating: Int, opponent: Int, score: Double) -> Int {
        let expected = 1.0 / (1.0 + pow(10.0, Double(opponent - rating) / 400.0))
        return Int((kFactor * (score - expected)).rounded())
    }
}

extension User {
    /// Display-name policy: 3–24 characters, letters/digits/space/underscore/hyphen.
    static func validateDisplayName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...24).contains(trimmed.count) else {
            throw Abort(.badRequest, reason: "display name must be 3-24 characters")
        }
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: " _-"))
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else {
            throw Abort(.badRequest, reason: "display name contains invalid characters")
        }
        return trimmed
    }

    static func generatedGuestName() -> String {
        "Guest-\(Int.random(in: 1000...9999))"
    }
}
