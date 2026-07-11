import Vapor
import Fluent

/// Erases an account in place (#108, App Review 5.1.1(v) / GDPR art. 17
/// erasure): the user row and every refresh token are deleted; finished
/// games are kept but anonymized. Anonymizing rather than deleting keeps
/// opponents' game history and the leaderboard intact — their ratings were
/// earned in those games — while the records stop being linkable to the
/// erased person, which satisfies the erasure right either way.
enum AccountDeletion {
    /// Stand-in identity stamped on anonymized game records. The zero UUID
    /// can never collide with a real account (IDs are random v4), and one
    /// shared sentinel for everyone means erased players can't even be
    /// correlated across their own past games.
    static let anonymizedPlayerID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// Neutral display name shown in opponents' histories. Deliberately not
    /// a valid user display name (too long is fine; it just never came from
    /// registration) and stored denormalized like every other record name.
    static let anonymizedPlayerName = "Deleted player"

    /// Deletes `userID` and everything linkable to it, atomically: game
    /// records are anonymized, refresh tokens and the user row removed.
    /// Once the row is gone, every outstanding bearer JWT for the account
    /// stops authenticating too — `Request.authenticatedUserID()` resolves
    /// the row on every request precisely so deletion is immediate.
    static func delete(userID: UUID, on db: Database) async throws {
        try await db.transaction { db in
            try await GameRecord.query(on: db)
                .set(\.$whiteID, to: anonymizedPlayerID)
                .set(\.$whiteName, to: anonymizedPlayerName)
                .filter(\.$whiteID == userID)
                .update()
            try await GameRecord.query(on: db)
                .set(\.$blackID, to: anonymizedPlayerID)
                .set(\.$blackName, to: anonymizedPlayerName)
                .filter(\.$blackID == userID)
                .update()
            // The FK cascade covers Postgres; delete tokens explicitly anyway
            // so behavior doesn't depend on SQLite's foreign_keys pragma in
            // dev/test (same reasoning as GuestAccountCleanup).
            try await RefreshToken.query(on: db)
                .filter(\.$user.$id == userID)
                .delete()
            try await User.query(on: db)
                .filter(\.$id == userID)
                .delete()
        }
    }
}
