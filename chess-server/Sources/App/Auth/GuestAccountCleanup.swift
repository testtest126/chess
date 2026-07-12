import Vapor
import Fluent

/// Deletes abandoned guest accounts: never linked to an Apple ID, never
/// finished a game, and inactive for the retention period. Registration is
/// unauthenticated, so without this the users table grows with every scripted
/// or one-tap-and-gone visitor (see #32).
///
/// "Inactive" is inferred from refresh-token rotation: the client exchanges
/// its refresh token on every online session and each exchange re-issues the
/// token with a fresh `expiresAt`, so the newest token's issue time is the
/// account's last activity. An old guest account with no tokens at all is
/// unrecoverable by its owner (the token was the only credential) and is
/// deleted too.
enum GuestAccountCleanup {
    /// How long an abandoned guest account is kept.
    static let retention: TimeInterval = 30 * 24 * 3600

    /// Max IDs per IN (…) query, so bind counts stay under the driver ceiling
    /// (SQLite ~32k, Postgres ~65k) even for the two-column game lookup.
    static let batchSize = 1000

    /// Runs one cleanup pass and returns how many accounts were deleted.
    @discardableResult
    static func run(on db: Database, now: Date = Date()) async throws -> Int {
        let cutoff = now.addingTimeInterval(-retention)
        // Tokens live `RefreshToken.lifetime` from issue, so "issued after the
        // cutoff" is "expires after cutoff + lifetime".
        let activeThreshold = cutoff.addingTimeInterval(RefreshToken.lifetime)

        // Guests old enough to be candidates at all.
        let candidates = try await User.query(on: db)
            .filter(\.$appleUserID == .null)
            .filter(\.$createdAt < cutoff)
            .all()
        let candidateIDs = try candidates.map { try $0.requireID() }
        guard !candidateIDs.isEmpty else { return 0 }

        // Process candidates in batches so no single IN (…) query exceeds the
        // driver's bind-parameter ceiling (SQLite ~32k, Postgres ~65k). Past
        // ~16k candidates the two-column game query blew the limit, threw, and
        // — the error being swallowed by the scheduler — stopped guest cleanup
        // permanently, growing the users table without bound (#155, M3).
        var removed = 0
        for start in stride(from: 0, to: candidateIDs.count, by: batchSize) {
            let batch = Array(candidateIDs[start ..< min(start + batchSize, candidateIDs.count)])

            // Still active: a refresh token issued within the retention period.
            let activeIDs = Set(
                try await RefreshToken.query(on: db)
                    .filter(\.$user.$id ~~ batch)
                    .filter(\.$expiresAt > activeThreshold)
                    .all()
                    .map { $0.$user.id }
            )

            // Has a game history worth keeping (either color; game_records has
            // no FK to users, so this is the join).
            let playerIDs = Set(
                try await GameRecord.query(on: db)
                    .group(.or) { or in
                        or.filter(\.$whiteID ~~ batch)
                        or.filter(\.$blackID ~~ batch)
                    }
                    .all()
                    .flatMap { [$0.whiteID, $0.blackID] }
            )

            let deletable = batch.filter { !activeIDs.contains($0) && !playerIDs.contains($0) }
            guard !deletable.isEmpty else { continue }

            // The FK cascade covers Postgres; delete tokens explicitly anyway so
            // behavior doesn't depend on SQLite's foreign_keys pragma in dev/test.
            try await RefreshToken.query(on: db)
                .filter(\.$user.$id ~~ deletable)
                .delete()
            // Re-assert appleUserID == null in the delete: if an account linked
            // Apple between the candidate read above and here it is now
            // recoverable and must not be reaped (#155, L1 TOCTOU).
            try await User.query(on: db)
                .filter(\.$id ~~ deletable)
                .filter(\.$appleUserID == .null)
                .delete()
            removed += deletable.count
        }
        return removed
    }
}

/// Runs `GuestAccountCleanup` once at boot and then on a fixed interval
/// (AUTH_CLEANUP_INTERVAL_HOURS, default 24) for the application's lifetime.
final class GuestCleanupScheduler: LifecycleHandler, @unchecked Sendable {
    private var task: Task<Void, Never>?

    func didBoot(_ app: Application) throws {
        let hours = Environment.get("AUTH_CLEANUP_INTERVAL_HOURS").flatMap(Double.init) ?? 24
        let interval = Duration.seconds(hours * 3600)
        task = Task {
            while !Task.isCancelled {
                do {
                    let removed = try await GuestAccountCleanup.run(on: app.db)
                    if removed > 0 {
                        app.logger.info("guest cleanup removed \(removed) abandoned account(s)")
                    }
                } catch {
                    app.logger.report(error: error)
                }
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return // cancelled during shutdown
                }
            }
        }
    }

    func shutdown(_ app: Application) {
        task?.cancel()
    }
}
