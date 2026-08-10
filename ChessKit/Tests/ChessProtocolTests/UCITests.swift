import XCTest
import ChessKit
@testable import ChessProtocol

final class UCITests: XCTestCase {
    private func makeAdapter() -> UCIEngine {
        UCIEngine(engine: NegamaxEngine(name: "TestEngine", author: "Tester"), defaultDepth: 2)
    }

    func testUCIHandshake() {
        let uci = makeAdapter()
        let response = uci.process("uci")
        XCTAssertEqual(response.first, "id name TestEngine")
        XCTAssertTrue(response.contains("id author Tester"))
        XCTAssertEqual(response.last, "uciok")
    }

    func testIsReady() {
        XCTAssertEqual(makeAdapter().process("isready"), ["readyok"])
    }

    func testPositionStartposWithMoves() {
        let uci = makeAdapter()
        uci.process("position startpos moves e2e4 e7e5 g1f3")
        var expected = Board()
        for m in ["e2e4", "e7e5", "g1f3"] { expected = expected.making(Move(uci: m)!)! }
        XCTAssertEqual(uci.currentBoard.fen, expected.fen)
    }

    func testPositionFEN() {
        let uci = makeAdapter()
        let fen = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"
        uci.process("position fen \(fen)")
        XCTAssertEqual(uci.currentBoard.fen, fen)
    }

    func testPositionFENWithMoves() {
        let uci = makeAdapter()
        let fen = "4k3/8/8/8/8/8/4P3/4K3 w - - 0 1"
        uci.process("position fen \(fen) moves e2e4")
        XCTAssertEqual(uci.currentBoard[Sq.parse("e4")!], Piece(color: .white, kind: .pawn))
        XCTAssertNil(uci.currentBoard[Sq.parse("e2")!])
    }

    func testPositionShortFENWithMoves() {
        // A 4-field FEN (no halfmove/fullmove counters) followed by moves.
        // The "moves" keyword must not be absorbed into the FEN, or the move
        // is silently dropped and e2e4 is never applied.
        let uci = makeAdapter()
        uci.process("position fen 4k3/8/8/8/8/8/4P3/4K3 w - - moves e2e4")
        XCTAssertEqual(uci.currentBoard[Sq.parse("e4")!], Piece(color: .white, kind: .pawn))
        XCTAssertNil(uci.currentBoard[Sq.parse("e2")!])
    }

    func testUCINewGameResets() {
        let uci = makeAdapter()
        uci.process("position startpos moves e2e4")
        uci.process("ucinewgame")
        XCTAssertEqual(uci.currentBoard.fen, Board.startingFEN)
    }

    func testGoReturnsBestMoveAndInfo() {
        let uci = makeAdapter()
        uci.process("position startpos")
        let response = uci.process("go depth 2")
        XCTAssertTrue(response.contains { $0.hasPrefix("info depth 2 score cp") })
        let bestmove = response.last!
        XCTAssertTrue(bestmove.hasPrefix("bestmove "))
        // The move must be legal in the current position.
        let uciMove = String(bestmove.dropFirst("bestmove ".count))
        XCTAssertTrue(Board().legalMoves().contains(Move(uci: uciMove)!))
    }

    func testGoReportsMate() {
        let uci = makeAdapter()
        uci.process("position fen 6k1/5ppp/8/8/8/8/8/R3K3 w - - 0 1")
        let response = uci.process("go depth 2")
        XCTAssertTrue(response.contains { $0.contains("score mate 1") })
        XCTAssertEqual(response.last, "bestmove a1a8")
    }

    func testQuitSetsFlag() {
        let uci = makeAdapter()
        XCTAssertFalse(uci.shouldQuit)
        uci.process("quit")
        XCTAssertTrue(uci.shouldQuit)
    }

    func testMalformedPositionIsIgnored() {
        let uci = makeAdapter()
        uci.process("position startpos moves e2e4")
        let before = uci.currentBoard.fen
        uci.process("position fen not-a-valid-fen")
        XCTAssertEqual(uci.currentBoard.fen, before) // unchanged
    }

    func testMateMovesConversion() {
        XCTAssertEqual(UCIEngine.mateMoves(fromPlies: 1), 1)
        XCTAssertEqual(UCIEngine.mateMoves(fromPlies: 2), 1)
        XCTAssertEqual(UCIEngine.mateMoves(fromPlies: 3), 2)
        XCTAssertEqual(UCIEngine.mateMoves(fromPlies: -3), -2)
    }

    // MARK: - Clock management (wtime/btime/winc/binc)

    func testClockBudgetNilWithoutOwnTime() {
        // White to move but only btime was sent: nothing to budget from.
        XCTAssertNil(UCIEngine.clockBudget(sideToMove: .white, wtimeMs: nil, btimeMs: 5000, wincMs: nil, bincMs: nil))
    }

    func testClockBudgetPicksOwnClockAndIncrement() {
        let white = UCIEngine.clockBudget(sideToMove: .white, wtimeMs: 20_000, btimeMs: 1, wincMs: 1000, bincMs: 1)!
        let black = UCIEngine.clockBudget(sideToMove: .black, wtimeMs: 1, btimeMs: 20_000, wincMs: 1, bincMs: 1000)!
        // Same clock/increment on the correct side should yield the same budget.
        XCTAssertEqual(white, black, accuracy: 0.001)
        // ~1/20th of (20000 - 200 safety) plus 80% of the 1000ms increment.
        XCTAssertEqual(white, 1_790.0 / 1000, accuracy: 0.001)
    }

    func testClockBudgetGrowsWithIncrement() {
        let noInc = UCIEngine.clockBudget(sideToMove: .white, wtimeMs: 10_000, btimeMs: nil, wincMs: nil, bincMs: nil)!
        let withInc = UCIEngine.clockBudget(sideToMove: .white, wtimeMs: 10_000, btimeMs: nil, wincMs: 2000, bincMs: nil)!
        XCTAssertGreaterThan(withInc, noInc)
    }

    func testClockBudgetCappedAtHalfClock() {
        // A huge increment shouldn't let one move eat the whole clock.
        let budget = UCIEngine.clockBudget(sideToMove: .white, wtimeMs: 1000, btimeMs: nil, wincMs: 100_000, bincMs: nil)!
        XCTAssertLessThanOrEqual(budget, 0.5)
    }

    func testClockBudgetNeverZeroWhenFlagging() {
        let budget = UCIEngine.clockBudget(sideToMove: .white, wtimeMs: 0, btimeMs: nil, wincMs: 0, bincMs: nil)!
        XCTAssertGreaterThan(budget, 0)
    }

    func testGoWithClockFieldsReturnsLegalMove() {
        let uci = makeAdapter()
        uci.process("position startpos")
        let response = uci.process("go wtime 2000 btime 2000 winc 0 binc 0")
        let bestmove = response.last!
        XCTAssertTrue(bestmove.hasPrefix("bestmove "))
        let uciMove = String(bestmove.dropFirst("bestmove ".count))
        XCTAssertTrue(Board().legalMoves().contains(Move(uci: uciMove)!))
    }

    func testGoUsesBlacksClockWhenBlackToMove() {
        let uci = makeAdapter()
        // After 1.e4, black is to move: btime should govern, not wtime.
        uci.process("position startpos moves e2e4")
        let response = uci.process("go wtime 1 btime 2000 winc 0 binc 0")
        let bestmove = response.last!
        let uciMove = String(bestmove.dropFirst("bestmove ".count))
        let board = Board().making(Move(uci: "e2e4")!)!
        XCTAssertTrue(board.legalMoves().contains(Move(uci: uciMove)!))
    }

    func testGoMovetimeTakesPrecedenceOverClock() {
        let uci = makeAdapter()
        uci.process("position startpos")
        // If both are sent, the explicit movetime should be used, not a
        // clock-derived budget that would want a `depth` info line at 64.
        let response = uci.process("go movetime 20 wtime 999999 btime 999999")
        XCTAssertTrue(response.last!.hasPrefix("bestmove "))
    }
}
