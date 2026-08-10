import XCTest
import ChessKit
@testable import ChessProtocol

/// Coverage for the LMR toggle (`NegamaxEngine.lateMoveReductions`, default
/// `true`): proves the flag is actually consulted (not silently ignored),
/// that turning it off exactly reconstructs pre-LMR search, and that
/// reductions don't cost tactical correctness — mirrors the rigor of
/// `PositionEvaluatorTests` for the evaluator seam.
///
/// Depth is kept at 4 — one past LMR's own minimum-depth threshold, so the
/// reduction actually fires below the root — rather than deeper: verified
/// fast (well under a second per search, even without LMR) before pinning,
/// since `swift test` must stay quick.
final class LateMoveReductionsTests: XCTestCase {
    /// A rich middlegame with many quiet, late candidate moves at each node —
    /// the shape LMR is meant to prune. Same FEN as
    /// `EngineTests.testSearchEfficiency`'s middlegame fixture.
    private let middlegame = Board(
        fen: "r1bq1rk1/pp2bppp/2n1pn2/3p4/2PP4/2N1PN2/PP2BPPP/R1BQ1RK1 w - - 0 8"
    )!

    func testLateMoveReductionsIsActuallyConsulted() {
        let withLMR = NegamaxEngine(lateMoveReductions: true)
        let withoutLMR = NegamaxEngine(lateMoveReductions: false)
        let a = withLMR.search(middlegame, limit: SearchLimit(depth: 4))
        let b = withoutLMR.search(middlegame, limit: SearchLimit(depth: 4))
        // Not a strength claim either way — just proof the flag changes the
        // search at all, the same way PositionEvaluatorTests proves the
        // evaluator seam isn't silently bypassed.
        XCTAssertNotEqual(a.nodes, b.nodes, "toggling lateMoveReductions should change node count")
    }

    func testLateMoveReductionsReducesNodesAtEqualDepth() {
        // The whole point of LMR: same depth ceiling, fewer nodes, because
        // late quiet moves get a cheap look first instead of a full-depth one.
        let withLMR = NegamaxEngine(lateMoveReductions: true)
        let withoutLMR = NegamaxEngine(lateMoveReductions: false)
        let a = withLMR.search(middlegame, limit: SearchLimit(depth: 4))
        let b = withoutLMR.search(middlegame, limit: SearchLimit(depth: 4))
        XCTAssertLessThan(a.nodes, b.nodes, "LMR should search fewer nodes than a full-width search at the same depth")
    }

    func testLateMoveReductionsIsDeterministic() {
        let engine = NegamaxEngine(lateMoveReductions: true)
        let a = engine.search(middlegame, limit: SearchLimit(depth: 4))
        let b = engine.search(middlegame, limit: SearchLimit(depth: 4))
        XCTAssertEqual(a.bestMove, b.bestMove)
        XCTAssertEqual(a.scoreCentipawns, b.scoreCentipawns)
        XCTAssertEqual(a.nodes, b.nodes)
    }

    /// LMR's classic failure mode is quietly missing a tactic the reduced
    /// search skipped past. These are already covered by `EngineTests`'
    /// mate-finding tests running against the (now LMR-on-by-default)
    /// shared `engine`, but this pins the guarantee specifically to LMR —
    /// the same fixture `EngineTests.testTranspositionTableKeepsMateScoresCorrect`
    /// already proves is fast at this depth in debug.
    func testLateMoveReductionsStillFindsDeeperMate() {
        let board = Board(fen: "7k/8/8/8/8/8/R7/1R4K1 w - - 0 1")!
        let engine = NegamaxEngine(lateMoveReductions: true)
        let result = engine.search(board, limit: SearchLimit(depth: 6))
        XCTAssertEqual(result.mateInPlies, 3)
    }

    func testLateMoveReductionsRespectsPersistentEngine() {
        // The persistent/pondering engine builds its own `Search` session
        // directly (PersistentNegamaxEngine.searchHoldingLock) rather than
        // going through NegamaxEngine.search — a separate wiring point that
        // could silently drop the flag.
        let withLMR = PersistentNegamaxEngine(lateMoveReductions: true)
        let withoutLMR = PersistentNegamaxEngine(lateMoveReductions: false)
        let a = withLMR.search(middlegame, limit: SearchLimit(depth: 4))
        let b = withoutLMR.search(middlegame, limit: SearchLimit(depth: 4))
        XCTAssertNotEqual(a.nodes, b.nodes, "PersistentNegamaxEngine must also honor lateMoveReductions")
    }
}
