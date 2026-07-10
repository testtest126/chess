import Vapor
import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import JWT

public func configure(_ app: Application) async throws {
    // MARK: Database
    // Postgres in deployment (DATABASE_URL), SQLite file for local development,
    // in-memory SQLite under test.
    if let databaseURL = Environment.get("DATABASE_URL") {
        try app.databases.use(.postgres(url: databaseURL), as: .psql)
    } else if app.environment == .testing {
        app.databases.use(.sqlite(.memory), as: .sqlite)
    } else {
        guard app.environment != .production else {
            app.logger.critical("DATABASE_URL must be set in production")
            throw Abort(.internalServerError, reason: "missing DATABASE_URL")
        }
        app.databases.use(.sqlite(.file("chess-dev.sqlite")), as: .sqlite)
    }

    app.migrations.add(CreateUser())
    app.migrations.add(CreateRefreshToken())
    app.migrations.add(CreateGameRecord())
    app.migrations.add(AddUserRating())
    try await app.autoMigrate()

    // MARK: JWT signing key
    // The signing secret is mandatory outside development so tokens survive
    // restarts and can never fall back to a known value.
    if let secret = Environment.get("JWT_SECRET") {
        app.jwt.signers.use(.hs256(key: secret))
    } else {
        guard app.environment == .development || app.environment == .testing else {
            app.logger.critical("JWT_SECRET must be set in production")
            throw Abort(.internalServerError, reason: "missing JWT_SECRET")
        }
        app.logger.warning("JWT_SECRET not set; using an insecure development-only key")
        app.jwt.signers.use(.hs256(key: "insecure-development-key-do-not-deploy"))
    }

    // MARK: Realtime coordinator
    app.gameCoordinator = GameCoordinator(app: app)

    try routes(app)
}
