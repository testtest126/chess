import Testing
import ChessKit
@testable import ios_chess_client

/// Spoken forms of played moves: VoiceOver reads these, so they must name
/// the mover, the piece, and the outcome rather than SAN shorthand.
@MainActor
struct MoveAnnouncerTests {

    private func lastEntry(after uciMoves: [String]) throws -> Game.HistoryEntry {
        let game = try Game.from(uciMoves: uciMoves)
        return try #require(game.history.last)
    }

    @Test func quietPawnMove() throws {
        let entry = try lastEntry(after: ["e2e4"])
        #expect(MoveAnnouncer.spokenDescription(of: entry) == "White: Pawn to e4")
    }

    @Test func captureNamesTheSquare() throws {
        let entry = try lastEntry(after: ["e2e4", "d7d5", "e4d5"])
        #expect(MoveAnnouncer.spokenDescription(of: entry) == "White: Pawn takes on d5")
    }

    @Test func checkSuffix() throws {
        let entry = try lastEntry(after: ["e2e4", "f7f6", "d1h5"])
        #expect(MoveAnnouncer.spokenDescription(of: entry) == "White: Queen to h5, check")
    }

    @Test func checkmateSuffixAndBlackMover() throws {
        // Fool's mate.
        let entry = try lastEntry(after: ["f2f3", "e7e5", "g2g4", "d8h4"])
        #expect(MoveAnnouncer.spokenDescription(of: entry) == "Black: Queen to h4, checkmate")
    }

    @Test func kingsideCastle() throws {
        let entry = try lastEntry(after: [
            "e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5", "e1g1",
        ])
        #expect(MoveAnnouncer.spokenDescription(of: entry) == "White: castles kingside")
    }

    @Test func capturePromotionNamesPieceAndSquare() throws {
        let entry = try lastEntry(after: [
            "a2a4", "b7b5", "a4b5", "a7a6", "b5a6", "c8b7", "a6b7", "b8c6", "b7a8q",
        ])
        #expect(MoveAnnouncer.spokenDescription(of: entry)
                == "White: pawn takes and promotes to Queen on a8")
    }
}
