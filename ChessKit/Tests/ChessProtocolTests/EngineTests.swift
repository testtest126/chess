import XCTest
import ChessKit
@testable import ChessProtocol

final class EngineTests: XCTestCase {

    private let engine = NegamaxEngine()

    func testFindsMateInOne() {
        // White: Qh5, Ke1; Black: Ke8 with a wall of pawns — Qe8 is not it, but
        // back-rank style. Use a clean forced mate: Q on g7 supported, king boxed.
        // Simpler: "6k1/5ppp/8/8/8/8/8/R3K3 w - - 0 1" — Ra8 is mate.
        let board = Board(fen: "6k1/5ppp/8/8/8/8/8/R3K3 w - - 0 1")!
        let result = engine.search(board, limit: SearchLimit(depth: 2))
        XCTAssertEqual(result.bestMove?.uci, "a1a8")
        XCTAssertNotNil(result.mateInPlies)
        XCTAssertEqual(result.mateInPlies, 1)
    }

    func testCapturesFreeQueen() {
        // Black queen on d4 is hanging to the pawn on e3; White should take it.
        let board = Board(fen: "4k3/8/8/8/3q4/4P3/8/4K3 w - - 0 1")!
        let result = engine.search(board, limit: SearchLimit(depth: 2))
        XCTAssertEqual(result.bestMove?.uci, "e3d4")
        // Capturing the queen with a pawn leaves White a pawn up on the board.
        XCTAssertGreaterThan(result.scoreCentipawns, 0)
    }

    func testTerminalPositionReturnsNoMove() {
        // Fool's-mate final position: black to move is checkmated? No — set an
        // actual checkmate with white to move and mated.
        // "rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3" is Fool's mate.
        let board = Board(fen: "rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3")!
        XCTAssertTrue(board.legalMoves().isEmpty)
        let result = engine.search(board, limit: .default)
        XCTAssertNil(result.bestMove)
        XCTAssertEqual(result.mateInPlies, 0)
    }

    func testSearchIsDeterministic() {
        let board = Board()
        let a = engine.search(board, limit: SearchLimit(depth: 3))
        let b = engine.search(board, limit: SearchLimit(depth: 3))
        XCTAssertEqual(a.bestMove, b.bestMove)
        XCTAssertEqual(a.scoreCentipawns, b.scoreCentipawns)
        XCTAssertEqual(a.nodes, b.nodes)
    }

    func testMatePliesConversion() {
        // Scores near the mate bound decode to the right ply distance.
        XCTAssertEqual(NegamaxEngine.matePlies(from: NegamaxEngine.mateScore - 1), 1)
        XCTAssertEqual(NegamaxEngine.matePlies(from: -(NegamaxEngine.mateScore - 3)), -3)
        XCTAssertNil(NegamaxEngine.matePlies(from: 250))
    }
}
