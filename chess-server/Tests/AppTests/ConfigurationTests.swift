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
