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

    func testRecognizesPerpetualCheckAsDraw() {
        // White is down a rook and a pawn, but the black king is confined to
        // g8/h8 and White has a forced perpetual check — 1.Qg6+ Kh8 2.Qh6+ Kg8
        // returns to the start position. Without repetition awareness the search
        // values the line by material and reports White as lost; recognizing the
        // repeat scores that line a draw, the best White has, so the engine no
        // longer reports a loss. (Position confirmed drawn by an independent
        // engine at both shallow and deep search.)
        let board = Board(fen: "6k1/8/3K3Q/q7/p7/8/1r6/8 w - - 0 1")!
        let result = engine.search(board, limit: SearchLimit(depth: 8))
        XCTAssertGreaterThan(result.scoreCentipawns, -50, "a forced perpetual check is a draw, not a loss")
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

    func testQuiescenceAvoidsHorizonBlunder() {
        // The e5 pawn is defended by d6. A pure depth-1 search would grab it
        // (+100 at the horizon); quiescence sees the recapture and declines.
        let board = Board(fen: "4k3/8/3p4/4p3/8/8/4Q3/4K3 w - - 0 1")!
        let result = engine.search(board, limit: SearchLimit(depth: 1))
        XCTAssertNotEqual(result.bestMove?.uci, "e2e5", "queen should not grab the defended pawn")
    }

    func testFindsMateInTwo() {
        // Rook ladder: 1.Ra7 (confining the king) Kg8 2.Rb8# — or the mirror
        // starting with Rb7. Either way it's mate in two (3 plies).
        let board = Board(fen: "7k/8/8/8/8/8/R7/1R4K1 w - - 0 1")!
        let result = engine.search(board, limit: SearchLimit(depth: 4))
        XCTAssertEqual(result.mateInPlies, 3)
    }

    func testMoveTimeIsRespected() {
        let board = Board(fen: "r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4")!
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let result = engine.search(board, limit: SearchLimit(depth: 64, moveTime: 0.1))
            XCTAssertNotNil(result.bestMove)
        }
        // Soft budget: one pass may overshoot slightly, but not by much.
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    func testIterativeDeepeningReportsCompletedDepth() {
        let board = Board()
        let result = engine.search(board, limit: SearchLimit(depth: 3))
        XCTAssertEqual(result.depth, 3)
        XCTAssertNotNil(result.bestMove)
    }

    // MARK: - Opening book

    func testStandardBookCoversCommonOpenings() {
        let book = OpeningBook.standard
        XCTAssertGreaterThan(book.positionCount, 40)
        // The initial position offers at least the three main first moves.
        let firstMoves = Set(book.moves(for: Board()).map(\.uci))
        XCTAssertTrue(firstMoves.isSuperset(of: ["e2e4", "d2d4", "c2c4"]))
        // Transposition-friendly keying: 1.e4 has book replies.
        let afterE4 = Board(fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1")!
        XCTAssertFalse(book.moves(for: afterE4).isEmpty)
    }

    func testBookMoveIsInstantAndLegal() {
        let bookEngine = NegamaxEngine(book: .standard)
        let board = Board()
        let result = bookEngine.search(board, limit: .default)
        XCTAssertEqual(result.nodes, 0, "book hits shouldn't search")
        let move = try! XCTUnwrap(result.bestMove)
        XCTAssertTrue(board.isLegal(move))
    }

    func testOutOfBookFallsBackToSearch() {
        let bookEngine = NegamaxEngine(book: .standard)
        // 1.a3 is not in any book line.
        let board = Board(fen: "rnbqkbnr/pppppppp/8/8/8/P7/1PPPPPPP/RNBQKBNR b KQkq - 0 1")!
        let result = bookEngine.search(board, limit: SearchLimit(depth: 2))
        XCTAssertGreaterThan(result.nodes, 0)
        XCTAssertNotNil(result.bestMove)
    }

    func testSearchEfficiency() {
        // Node-count regression guard: ordering + TT + null move should keep
        // fixed-depth searches small. Deterministic, so bounds aren't flaky —
        // they only trip if a change genuinely regresses pruning.
        let start = engine.search(Board(), limit: SearchLimit(depth: 4))
        print("efficiency: startpos depth 4 -> \(start.nodes) nodes")
        XCTAssertLessThan(start.nodes, 100_000)

        let middlegame = Board(fen: "r1bq1rk1/pp2bppp/2n1pn2/3p4/2PP4/2N1PN2/PP2BPPP/R1BQ1RK1 w - - 0 8")!
        let result = engine.search(middlegame, limit: SearchLimit(depth: 3))
        print("efficiency: middlegame depth 3 -> \(result.nodes) nodes")
        XCTAssertLessThan(result.nodes, 50_000)
    }

    // MARK: - Transposition table

    func testTranspositionTableKeepsMateScoresCorrect() {
        // Same mate-in-two, deeper search: TT hits at different plies must not
        // corrupt the mate distance.
        let board = Board(fen: "7k/8/8/8/8/8/R7/1R4K1 w - - 0 1")!
        let result = engine.search(board, limit: SearchLimit(depth: 6))
        XCTAssertEqual(result.mateInPlies, 3)
    }

    func testMatePliesConversion() {
        // Scores near the mate bound decode to the right ply distance.
        XCTAssertEqual(NegamaxEngine.matePlies(from: NegamaxEngine.mateScore - 1), 1)
        XCTAssertEqual(NegamaxEngine.matePlies(from: -(NegamaxEngine.mateScore - 3)), -3)
        XCTAssertNil(NegamaxEngine.matePlies(from: 250))
    }
}
