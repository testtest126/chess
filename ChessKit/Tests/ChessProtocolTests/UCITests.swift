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
}
