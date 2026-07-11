import XCTest
@testable import ChessKit

final class SANTests: XCTestCase {
    private func san(_ fen: String, _ uci: String) -> String {
        let board = Board(fen: fen)!
        let move = Move(uci: uci)!
        return board.san(for: move)
    }

    func testBasicMoves() {
        XCTAssertEqual(san(Board.startingFEN, "e2e4"), "e4")
        XCTAssertEqual(san(Board.startingFEN, "g1f3"), "Nf3")
    }

    func testCastling() {
        let fen = "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1"
        XCTAssertEqual(san(fen, "e1g1"), "O-O")
        XCTAssertEqual(san(fen, "e1c1"), "O-O-O")
    }

    func testPawnCapture() {
        // White pawn on e4, black pawn on d5.
        let fen = "4k3/8/8/3p4/4P3/8/8/4K3 w - - 0 1"
        XCTAssertEqual(san(fen, "e4d5"), "exd5")
    }

    func testEnPassantSAN() {
        // Black just played ...c5; white pawn on b5 can take en passant on c6.
        let fen = "rnbqkbnr/pp1ppppp/8/1Pp5/8/8/P1PPPPPP/RNBQKBNR w KQkq c6 0 2"
        XCTAssertEqual(san(fen, "b5c6"), "bxc6")
    }

    func testPromotion() {
        // Black king on e6 so the new queen on a8 doesn't give check.
        let fen = "8/P7/4k3/8/8/8/8/4K3 w - - 0 1"
        XCTAssertEqual(san(fen, "a7a8q"), "a8=Q")
    }

    func testFileDisambiguation() {
        // Knights on c3 and g1 both reach e2.
        let fen = "4k3/8/8/8/8/2N5/8/4K1N1 w - - 0 1"
        XCTAssertEqual(san(fen, "c3e2"), "Nce2")
        XCTAssertEqual(san(fen, "g1e2"), "Nge2")
    }

    func testRankDisambiguation() {
        // Rooks on a1 and a8 both reach a4 (same file → disambiguate by rank).
        // Black king on e6 so neither rook move gives check.
        let fen = "R7/8/4k3/8/8/8/8/R3K3 w - - 0 1"
        XCTAssertEqual(san(fen, "a1a4"), "R1a4")
        XCTAssertEqual(san(fen, "a8a4"), "R8a4")
    }

    func testCheckAndCheckmateMarkers() {
        // Scholar's mate produces a check-free line ending in mate.
        var game = Game()
        let moves = ["e2e4", "e7e5", "f1c4", "b8c6", "d1h5", "g8f6", "h5f7"]
        for uci in moves { XCTAssertNoThrow(try game.play(uci: uci)) }
        XCTAssertEqual(game.history.map(\.san),
                       ["e4", "e5", "Bc4", "Nc6", "Qh5", "Nf6", "Qxf7#"])
        XCTAssertEqual(game.result, .whiteWins)
        XCTAssertEqual(game.endReason, .checkmate)
    }
}
