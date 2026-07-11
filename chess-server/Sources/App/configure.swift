import Vapor
import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import JWT

public func configure(_ app: Application) async throws {
    // MARK: Database

    // Postgres when DATABASE_URL is set; an explicit SQLite file when
    // SQLITE_PATH is (the zero-spend Fly deployment: one machine, one small
    // volume); in-memory SQLite under test; a local file for development.
    // Production still refuses to boot with neither — an *implicit* database
    // is how data quietly ends up on an ephemeral disk.
    if let databaseURL = Environment.get("DATABASE_URL") {
        try app.databases.use(.postgres(url: databaseURL), as: .psql)
    } else if let sqlitePath = Environment.get("SQLITE_PATH") {
        app.databases.use(.sqlite(.file(sqlitePath)), as: .sqlite)
    } else if app.environment == .testing {
        app.databases.use(.sqlite(.memory), as: .sqlite)
    } else {
        guard app.environment != .production else {
            app.logger.critical("set DATABASE_URL (postgres) or SQLITE_PATH (file) in production")
            throw Abort(.internalServerError, reason: "no database configured")
        }
        app.databases.use(.sqlite(.file("chess-dev.sqlite")), as: .sqlite)
    }

    app.migrations.add(CreateUser())
    app.migrations.add(CreateRefreshToken())
    app.migrations.add(CreateGameRecord())
    app.migrations.add(AddUserRating())
    app.migrations.add(AddUserAppleID())
    app.migrations.add(AddGameRecordTimeControl())
    app.migrations.add(CreateAppleNonce())
    app.migrations.add(CreateAuthRateWindow())
    try await app.autoMigrate()

    // MARK: JWT signing key

    // The signing secret is mandatory outside development so tokens survive
    // restarts and can never fall back to a known value.
    if let secret = Environment.get("JWT_SECRET") {
        await app.jwt.keys.add(hmac: HMACKey(from: secret), digestAlgorithm: .sha256)
    } else {
        guard app.environment == .development || app.environment == .testing else {
            app.logger.critical("JWT_SECRET must be set in production")
            throw Abort(.internalServerError, reason: "missing JWT_SECRET")
        }
        app.logger.warning("JWT_SECRET not set; using an insecure development-only key")
        await app.jwt.keys.add(hmac: HMACKey(from: "insecure-development-key-do-not-deploy"), digestAlgorithm: .sha256)
    }

    // MARK: Sign in with Apple

    // SIWA_APP_ID is the iOS app's bundle identifier; Apple identity tokens
    // are verified against it as the audience. The /auth/apple endpoint
    // returns 503 until this is configured.
    if let appleAppID = Environment.get("SIWA_APP_ID") {
        app.jwt.apple.applicationIdentifier = appleAppID
    }

    // MARK: Auth abuse protection (#32, #79)

    // Per-IP sliding-window throttle on /auth/*, counted in the database so
    // all instances share one budget. Effectively off under test so the
    // suite's rapid registrations pass; rate-limit tests install a tight
    // limiter themselves.
    let defaultLimit = app.environment == .testing ? Int.max : 10
    app.authRateLimiter = SlidingWindowRateLimiter(
        limit: Environment.get("AUTH_RATE_LIMIT").flatMap(Int.init) ?? defaultLimit,
        window: Environment.get("AUTH_RATE_LIMIT_WINDOW").flatMap(Double.init) ?? 60
    )
    // Reap abandoned guest accounts. Not under test: tests drive
    // GuestAccountCleanup.run directly.
    if app.environment != .testing {
        app.lifecycle.use(GuestCleanupScheduler())
    }

    // MARK: Realtime coordinator

    app.gameCoordinator = GameCoordinator(app: app)

    try routes(app)
}
