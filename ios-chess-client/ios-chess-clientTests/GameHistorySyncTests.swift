import Testing
import Foundation
import SwiftData
import ChessKit
import ChessOnline
@testable import ios_chess_client

/// The pure merge step of the server-history sync: which fetched records
/// become local rows, which are recognized as already present, and how
/// legacy rows are adopted.
@MainActor
struct GameHistorySyncTests {
    private let myID = UUID()
    private let opponentID = UUID()

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: SavedGame.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func record(
        id: UUID = UUID(),
        playedWhite: Bool = true,
        moves: String = "e2e4 e7e5",
        timeControl: TimeControl? = .blitz
    ) -> GameRecordDTO {
        GameRecordDTO(
            id: id,
            whiteID: playedWhite ? myID : opponentID,
            blackID: playedWhite ? opponentID : myID,
            whiteName: playedWhite ? "Me" : "Guest-9999",
            blackName: playedWhite ? "Guest-9999" : "Me",
            result: "1-0",
            endReason: "resignation",
            uciMoves: moves,
            finishedAt: Date(timeIntervalSince1970: 1_750_000_000),
            timeControl: timeControl
        )
    }

    private func savedGames(_ context: ModelContext) throws -> [SavedGame] {
        try context.fetch(FetchDescriptor<SavedGame>())
    }

    @Test func insertsMissingServerGamesWithDerivedColorAndOpponent() throws {
        let context = try makeContext()
        GameHistorySync.merge(records: [record(playedWhite: false)], into: context, myID: myID)

        let rows = try savedGames(context)
        try #require(rows.count == 1)
        #expect(rows[0].playerColor == .black)
        #expect(rows[0].opponentName == "Guest-9999")
        #expect(rows[0].timeControl == .blitz)
        #expect(rows[0].onlineGameID != nil)
        #expect(rows[0].difficulty == nil) // renders as an online game
        #expect(rows[0].moves == ["e2e4", "e7e5"])
    }

    @Test func skipsGamesAlreadyKnownByServerID() throws {
        let context = try makeContext()
        let serverID = UUID()
        context.insert(SavedGame(
            date: Date(), playerColor: .white, difficulty: nil,
            result: .whiteWins, endReason: .resignation,
            uciMoves: ["e2e4", "e7e5"], opponentName: "Guest-9999",
            onlineGameID: serverID, timeControl: .blitz
        ))

        GameHistorySync.merge(records: [record(id: serverID)], into: context, myID: myID)
        #expect(try savedGames(context).count == 1)
    }

    @Test func adoptsLegacyOnlineRowsByMoveList() throws {
        let context = try makeContext()
        // An online row saved before server identity existed: no id, no control.
        context.insert(SavedGame(
            date: Date(), playerColor: .white, difficulty: nil,
            result: .whiteWins, endReason: .resignation,
            uciMoves: ["e2e4", "e7e5"], opponentName: "Guest-9999"
        ))
        let serverID = UUID()

        GameHistorySync.merge(records: [record(id: serverID)], into: context, myID: myID)

        let rows = try savedGames(context)
        try #require(rows.count == 1) // adopted, not duplicated
        #expect(rows[0].onlineGameID == serverID)
        #expect(rows[0].timeControl == .blitz) // backfilled
    }

    @Test func engineGamesAreNeverAdopted() throws {
        let context = try makeContext()
        // An engine game that happens to share the move list.
        context.insert(SavedGame(
            date: Date(), playerColor: .white, difficulty: .casual,
            result: .whiteWins, endReason: .resignation,
            uciMoves: ["e2e4", "e7e5"]
        ))

        GameHistorySync.merge(records: [record()], into: context, myID: myID)

        let rows = try savedGames(context)
        #expect(rows.count == 2) // server game inserted alongside
        #expect(rows.contains { $0.difficulty == .casual && $0.onlineGameID == nil })
    }

    @Test func skipsRecordsWithoutMoves() throws {
        let context = try makeContext()
        GameHistorySync.merge(records: [record(moves: "")], into: context, myID: myID)
        #expect(try savedGames(context).isEmpty)
    }

    @Test func recordsWithoutControlStayUntagged() throws {
        let context = try makeContext()
        GameHistorySync.merge(records: [record(timeControl: nil)], into: context, myID: myID)
        #expect(try #require(try savedGames(context).first).timeControl == nil)
    }
}
