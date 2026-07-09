import XCTest
@testable import ChessKit

final class GameTests: XCTestCase {

    func testIllegalMoveThrows() {
        var game = Game()
        XCTAssertThrowsError(try game.play(uci: "e2e5")) { error in
            XCTAssertEqual(error as? ChessError, .illegalMove)
        }
    }

    func testPlayingAfterGameOverThrows() {
        var game = Game()
        for uci in ["f2f3", "e7e5", "g2g4", "d8h4"] { // Fool's mate
            XCTAssertNoThrow(try game.play(uci: uci))
        }
        XCTAssertEqual(game.result, .blackWins)
        XCTAssertEqual(game.endReason, .checkmate)
        XCTAssertThrowsError(try game.play(uci: "e1e2")) { error in
            XCTAssertEqual(error as? ChessError, .gameOver)
        }
    }

    func testPromotionDefaultsToQueen() {
        var game = try! Game(fen: "8/P7/4k3/8/8/8/8/4K3 w - - 0 1")
        let entry = try! game.play(uci: "a7a8") // no promotion suffix
        XCTAssertEqual(entry.san, "a8=Q")
        XCTAssertEqual(game.board[Sq.parse("a8")!], Piece(color: .white, kind: .queen))
    }

    func testThreefoldRepetition() {
        var game = Game()
        // Knights shuffle back to the start position twice over.
        let cycle = ["g1f3", "g8f6", "f3g1", "f6g8"]
        for _ in 0..<2 {
            for uci in cycle { XCTAssertNoThrow(try game.play(uci: uci)) }
        }
        XCTAssertEqual(game.result, .draw)
        XCTAssertEqual(game.endReason, .threefoldRepetition)
    }

    func testFiftyMoveRule() {
        let board = Board(fen: "4k3/8/8/8/8/8/8/4K2R w K - 100 80")!
        XCTAssertEqual(board.status, .fiftyMoveDraw)
    }

    func testInsufficientMaterial() {
        XCTAssertTrue(Board(fen: "8/8/8/4k3/8/8/8/4K3 w - - 0 1")!.hasInsufficientMaterial)   // K vs K
        XCTAssertTrue(Board(fen: "8/8/8/4k3/8/8/8/4KB2 w - - 0 1")!.hasInsufficientMaterial)  // K+B vs K
        XCTAssertTrue(Board(fen: "8/8/8/4k3/8/8/8/4KN2 w - - 0 1")!.hasInsufficientMaterial)  // K+N vs K
        XCTAssertFalse(Board(fen: "8/8/8/4k3/8/8/4P3/4K3 w - - 0 1")!.hasInsufficientMaterial) // pawn present
    }

    func testUCIMovesRoundTrip() {
        var game = Game()
        let moves = ["e2e4", "e7e5", "g1f3", "b8c6", "f1b5"] // Ruy Lopez opening
        for uci in moves { XCTAssertNoThrow(try game.play(uci: uci)) }
        XCTAssertEqual(game.uciMoves, moves)

        let rebuilt = try! Game.from(uciMoves: game.uciMoves)
        XCTAssertEqual(rebuilt.board.fen, game.board.fen)
        XCTAssertEqual(rebuilt.history.map(\.san), game.history.map(\.san))
    }

    func testPGNContainsMovesAndResult() {
        var game = Game()
        for uci in ["e2e4", "e7e5", "g1f3"] { try! game.play(uci: uci) }
        game.end(result: .draw, reason: .drawAgreement)
        let pgn = game.pgn(white: "Alice", black: "Bob")
        XCTAssertTrue(pgn.contains("[White \"Alice\"]"))
        XCTAssertTrue(pgn.contains("[Black \"Bob\"]"))
        XCTAssertTrue(pgn.contains("1. e4 e5 2. Nf3"))
        XCTAssertTrue(pgn.contains("1/2-1/2"))
    }
}
