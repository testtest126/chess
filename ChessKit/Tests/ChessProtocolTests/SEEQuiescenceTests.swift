import XCTest
import ChessKit
@testable import ChessProtocol

/// Coverage for the SEE-pruning toggle (`NegamaxEngine.seePruning`, default
/// `true`): proves the flag is actually consulted (not silently ignored) by
/// both engine types, that it reduces quiescence node count, that it stays
/// deterministic, and that it doesn't cost tactical correctness (a losing
/// capture pruned from quiescence must not blind the search to a real
/// tactic reached by a *different*, non-losing move).
final class SEEQuiescenceTests: XCTestCase {
    /// A tactical middlegame with several captures on the board, including
    /// losing ones for the side to move — the shape SEE pruning is meant to
    /// cut down in quiescence.
    private let tactical = Board(
        fen: "r2q1rk1/pp1n1ppp/2p1pn2/3pNb2/2PP4/2N1P3/PP2BPPP/R1BQ1RK1 w - - 0 1"
    )!

    func testSEEPruningIsActuallyConsulted() {
        let withSEE = NegamaxEngine(seePruning: true)
        let withoutSEE = NegamaxEngine(seePruning: false)
        let a = withSEE.search(tactical, limit: SearchLimit(depth: 4))
        let b = withoutSEE.search(tactical, limit: SearchLimit(depth: 4))
        XCTAssertNotEqual(a.nodes, b.nodes, "toggling seePruning should change node count")
    }

    func testSEEPruningReducesNodes() {
        // The whole point: quiescence spends fewer nodes once losing
        // captures are skipped instead of fully searched.
        let withSEE = NegamaxEngine(seePruning: true)
        let withoutSEE = NegamaxEngine(seePruning: false)
        let a = withSEE.search(tactical, limit: SearchLimit(depth: 4))
        let b = withoutSEE.search(tactical, limit: SearchLimit(depth: 4))
        XCTAssertLessThan(a.nodes, b.nodes, "SEE pruning should search fewer nodes than unpruned quiescence")
    }

    func testSEEPruningIsDeterministic() {
        let engine = NegamaxEngine(seePruning: true)
        let a = engine.search(tactical, limit: SearchLimit(depth: 4))
        let b = engine.search(tactical, limit: SearchLimit(depth: 4))
        XCTAssertEqual(a.bestMove, b.bestMove)
        XCTAssertEqual(a.scoreCentipawns, b.scoreCentipawns)
        XCTAssertEqual(a.nodes, b.nodes)
    }

    func testSEEPruningRespectsPersistentEngine() {
        // PersistentNegamaxEngine.searchHoldingLock builds its own `Search`
        // session directly rather than going through NegamaxEngine.search —
        // a separate wiring point that could silently drop the flag.
        let withSEE = PersistentNegamaxEngine(seePruning: true)
        let withoutSEE = PersistentNegamaxEngine(seePruning: false)
        let a = withSEE.search(tactical, limit: SearchLimit(depth: 4))
        let b = withoutSEE.search(tactical, limit: SearchLimit(depth: 4))
        XCTAssertNotEqual(a.nodes, b.nodes, "PersistentNegamaxEngine must also honor seePruning")
    }

    func testSEEPruningStillFindsMateInTwo() {
        // Same mate-in-two fixture EngineTests uses. A quiescence bug that
        // pruned too aggressively (e.g. pruning a check, or pruning while in
        // check) would plausibly hide a mate reached through a capture line.
        let board = Board(fen: "7k/8/8/8/8/8/R7/1R4K1 w - - 0 1")!
        let engine = NegamaxEngine(seePruning: true)
        let result = engine.search(board, limit: SearchLimit(depth: 4))
        XCTAssertEqual(result.mateInPlies, 3)
    }

    func testQueenStillDeclinesTheDefendedPawnWithSEEOn() {
        // EngineTests.testQuiescenceAvoidsHorizonBlunder's fixture: SEE
        // pruning must not change *this* answer — the queen still shouldn't
        // grab the defended pawn (it's a losing capture either way, whether
        // quiescence proves that by fully searching the recapture or by
        // pruning the capture as SEE-negative up front).
        let board = Board(fen: "4k3/8/3p4/4p3/8/8/4Q3/4K3 w - - 0 1")!
        let engine = NegamaxEngine(seePruning: true)
        let result = engine.search(board, limit: SearchLimit(depth: 1))
        XCTAssertNotEqual(result.bestMove?.uci, "e2e5", "queen should still not grab the defended pawn")
    }
}
