import Vapor
import Fluent

final class User: Model, Content, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "display_name")
    var displayName: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, displayName: String) {
        self.id = id
        self.displayName = displayName
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
