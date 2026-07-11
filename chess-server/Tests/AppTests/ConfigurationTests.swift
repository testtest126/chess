@testable import App
import XCTVapor

/// Boot-path configuration: which database the server selects, and when it
/// refuses to start at all.
final class ConfigurationTests: XCTestCase {
    func testProductionBootsWithExplicitSQLitePath() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-test-\(UUID().uuidString).sqlite").path
        setenv("SQLITE_PATH", path, 1)
        setenv("JWT_SECRET", "test-secret-for-boot", 1)
        defer {
            unsetenv("SQLITE_PATH")
            unsetenv("JWT_SECRET")
            try? FileManager.default.removeItem(atPath: path)
        }

        let app = try await Application.make(.production)
        do {
            try await configure(app)
        } catch {
            try? await app.asyncShutdown()
            return XCTFail("production must boot with an explicit SQLITE_PATH: \(error)")
        }
        try await app.asyncShutdown()
        // Migrations ran at boot, so the file exists.
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testProductionRefusesToBootWithoutJWTSecret() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-jwt-test-\(UUID().uuidString).sqlite").path
        setenv("SQLITE_PATH", path, 1)
        defer {
            unsetenv("SQLITE_PATH")
            unsetenv("JWT_SECRET")
            try? FileManager.default.removeItem(atPath: path)
        }
        // Explicitly remove JWT_SECRET to ensure it's not inherited.
        unsetenv("JWT_SECRET")

        let app = try await Application.make(.production)
        do {
            try await configure(app)
            try await app.asyncShutdown()
            XCTFail("production must refuse to boot without JWT_SECRET")
        } catch {
            try? await app.asyncShutdown()
        }
    }

    func testTestingEnvironmentBootsWithoutExplicitConfig() async throws {
        // The .testing environment should boot with in-memory SQLite and an
        // insecure development key — the default for all other tests.
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
        } catch {
            try? await app.asyncShutdown()
            return XCTFail("testing environment must boot without explicit config: \(error)")
        }
        try await app.asyncShutdown()
    }

    func testDevelopmentEnvironmentBootsWithLocalFile() async throws {
        // Development mode uses a local file database and insecure JWT key.
        unsetenv("DATABASE_URL")
        unsetenv("SQLITE_PATH")
        unsetenv("JWT_SECRET")
        let devPath = FileManager.default.currentDirectoryPath + "/chess-dev.sqlite"
        defer { try? FileManager.default.removeItem(atPath: devPath) }

        let app = try await Application.make(.development)
        do {
            try await configure(app)
        } catch {
            try? await app.asyncShutdown()
            return XCTFail("development environment must boot without explicit config: \(error)")
        }
        try await app.asyncShutdown()
    }

    func testProductionRefusesToBootWithoutAnyDatabase() async throws {
        setenv("JWT_SECRET", "test-secret-for-boot", 1)
        defer { unsetenv("JWT_SECRET") }

        let app = try await Application.make(.production)
        do {
            try await configure(app)
            try await app.asyncShutdown()
            XCTFail("production must refuse to boot with neither DATABASE_URL nor SQLITE_PATH")
        } catch {
            // Expected: an implicit database is how data quietly ends up on
            // an ephemeral disk.
            try? await app.asyncShutdown()
        }
    }
}
