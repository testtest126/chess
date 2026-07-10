import Foundation
import SwiftData
import ChessKit
import ChessOnline

/// Pulls the account's server-side game history into the local SwiftData
/// store, so online games played on other devices — or before a reinstall —
/// appear under Past Games. Local rows are the source of truth for engine
/// games; a sync only ever adds online games that are missing locally.
@MainActor
enum GameHistorySync {
    /// Offline-first: callers render local rows immediately and invoke this
    /// to fill in whatever the server has. No-ops without an account (never
    /// registers one just to fetch a necessarily empty history) and swallows
    /// network errors — the next appearance retries.
    static func sync(into context: ModelContext) async {
        guard let myID = AccountStore.shared.userID else { return }
        guard let records = try? await AccountStore.shared.fetchGames() else { return }
        merge(records: records, into: context, myID: myID)
    }

    /// Pure merge step, separated from account/network so tests can drive it.
    static func merge(records: [GameRecordDTO], into context: ModelContext, myID: UUID) {
        let existing = (try? context.fetch(FetchDescriptor<SavedGame>())) ?? []
        var knownIDs = Set(existing.compactMap(\.onlineGameID))
        // Online rows saved before server identity was recorded are matched
        // by move list and adopted rather than duplicated.
        var legacyByMoves: [String: SavedGame] = [:]
        for row in existing where row.onlineGameID == nil && row.difficulty == nil {
            legacyByMoves[row.uciMoves] = row
        }

        for record in records {
            guard !knownIDs.contains(record.id) else { continue }
            // A game abandoned before the first move has nothing to review;
            // local saves skip those too.
            guard !record.uciMoves.isEmpty else { continue }

            if let legacy = legacyByMoves[record.uciMoves] {
                legacy.onlineGameID = record.id
                if legacy.timeControlRaw == nil {
                    legacy.timeControlRaw = record.timeControl?.rawValue
                }
                knownIDs.insert(record.id)
                continue
            }

            let playedWhite = record.whiteID == myID
            context.insert(SavedGame(
                date: record.finishedAt,
                playerColor: playedWhite ? .white : .black,
                difficulty: nil,
                result: Game.Result(rawValue: record.result) ?? .ongoing,
                endReason: Game.EndReason(rawValue: record.endReason),
                uciMoves: record.uciMoves.split(separator: " ").map(String.init),
                opponentName: playedWhite ? record.blackName : record.whiteName,
                onlineGameID: record.id,
                timeControl: record.timeControl
            ))
            knownIDs.insert(record.id)
        }
    }
}
