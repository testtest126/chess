import XCTest
@testable import ChessKit
@testable import ChessProtocol

/// Always returns the same value regardless of the position — a decisive way
/// to prove ``NegamaxEngine`` actually consults the injected evaluator rather
/// than falling back to `Board.evaluateFast()` internally.
private struct ConstantEvaluator: PositionEvaluator {
    let value: Int
    func evaluate(_ board: Board) -> Int { value }
}

final class PositionEvaluatorTests: XCTestCase {
    func testDefaultEvaluatorMatchesEvaluateFast() {
        let evaluator = DefaultEvaluator()
        let board = Board()
        XCTAssertEqual(evaluator.evaluate(board), board.evaluateFast())

        var afterMoves = board
        afterMoves.apply(Move(uci: "e2e4")!)
        afterMoves.apply(Move(uci: "c7c5")!)
        XCTAssertEqual(evaluator.evaluate(afterMoves), afterMoves.evaluateFast())
    }

    /// With every leaf scoring the same constant, the negamax back-propagation
    /// (which flips sign each ply) must converge to exactly that constant at
    /// the root — a value nowhere close to the real material evaluation of
    /// the starting position, so this only passes if the injected evaluator
    /// is genuinely on the hot path.
    func testCustomEvaluatorIsActuallyConsulted() {
        let engine = NegamaxEngine(evaluator: ConstantEvaluator(value: 12345))
        let result = engine.search(Board(), limit: SearchLimit(depth: 1))
        XCTAssertEqual(result.scoreCentipawns, 12345)
    }

    /// Two engines differing only in evaluator must (in general) disagree on
    /// score for a position where the evaluators genuinely differ — proof the
    /// seam isn't silently ignored for one of the two engine types.
    func testDifferentEvaluatorsCanProduceDifferentScores() {
        let zero = NegamaxEngine(evaluator: ConstantEvaluator(value: 0))
        let nonzero = NegamaxEngine(evaluator: ConstantEvaluator(value: 500))
        let board = Board()
        let a = zero.search(board, limit: SearchLimit(depth: 1))
        let b = nonzero.search(board, limit: SearchLimit(depth: 1))
        XCTAssertNotEqual(a.scoreCentipawns, b.scoreCentipawns)
    }

    /// The seam threads through the persistent/pondering engine too.
    func testPersistentEngineAlsoConsultsCustomEvaluator() {
        let engine = PersistentNegamaxEngine(evaluator: ConstantEvaluator(value: 777))
        let result = engine.search(Board(), limit: SearchLimit(depth: 1))
        XCTAssertEqual(result.scoreCentipawns, 777)
    }
}
