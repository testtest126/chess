import Fluent

struct CreateUser: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(User.schema)
            .id()
            .field("display_name", .string, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(User.schema).delete()
    }
}

struct CreateRefreshToken: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(RefreshToken.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("token_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .unique(on: "token_hash")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(RefreshToken.schema).delete()
    }
}

struct CreateGameRecord: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(GameRecord.schema)
            .id()
            .field("white_id", .uuid, .required)
            .field("black_id", .uuid, .required)
            .field("white_name", .string, .required)
            .field("black_name", .string, .required)
            .field("result", .string, .required)
            .field("end_reason", .string, .required)
            .field("uci_moves", .string, .required)
            .field("finished_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(GameRecord.schema).delete()
    }
}
