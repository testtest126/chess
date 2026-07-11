import Fluent
import SQLKit

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

struct AddUserRating: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(User.schema)
            .field("rating", .int, .required, .sql(.default(1200)))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(User.schema)
            .deleteField("rating")
            .update()
    }
}

struct AddUserAppleID: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(User.schema)
            .field("apple_user_id", .string)
            .update()
        // SQLite can't add a UNIQUE constraint via ALTER TABLE; a partial
        // unique index does the same job and works on both SQLite and
        // Postgres (NULLs — unlinked accounts — are excluded by design).
        if let sql = database as? SQLDatabase {
            try await sql.raw("""
            CREATE UNIQUE INDEX IF NOT EXISTS idx_users_apple_user_id
            ON users (apple_user_id) WHERE apple_user_id IS NOT NULL
            """).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_users_apple_user_id").run()
        }
        try await database.schema(User.schema)
            .deleteField("apple_user_id")
            .update()
    }
}

struct AddGameRecordTimeControl: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(GameRecord.schema)
            .field("time_control", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(GameRecord.schema)
            .deleteField("time_control")
            .update()
    }
}

struct CreateAppleNonce: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(AppleNonce.schema)
            .id()
            .field("nonce_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .unique(on: "nonce_hash")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(AppleNonce.schema).delete()
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
