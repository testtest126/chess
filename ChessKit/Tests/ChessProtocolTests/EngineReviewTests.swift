import XCTest
import ChessKit
@testable import ChessProtocol

/// Regression tests for engine-backed game review (issue #31). The original
/// review compared a 1-ply best against the *static* eval after the move, so
/// hanging a piece to a recapture was judged as good. The evaluator-per-
/// position refactor already catches one-move recaptures; the engine
/// evaluator pins that guarantee and extends it to deeper tactics.
final class EngineReviewTests: XCTestCase {
    /// Fixed-depth, uncapped, bookless: fully deterministic.
    private let evaluator = NegamaxEngine().reviewEvaluator(limit: SearchLimit(depth: 3))

    private func game(_ ucis: [String]) -> Game {
        var g = Game()
        for uci in ucis { try! g.play(uci: uci) }
        return g
    }

    /// 1. e4 e5 2. Qh5 Nc6 3. Qxe5+?? — the queen falls to ...Nxe5. The 1-ply
    /// evaluator scored this as winning a pawn; the engine must call it a blunder.
    func testHangingTheQueenIsABlunder() {
        let g = game(["e2e4", "e7e5", "d1h5", "b8c6", "h5e5"])
        let review = GameReview(analyzing: g, evaluator: evaluator)

        let queenGrab = review.moves[4]
        XCTAssertEqual(queenGrab.san, "Qxe5+")
        XCTAssertEqual(queenGrab.mover, .white)
        XCTAssertGreaterThan(queenGrab.centipawnLoss, 250,
                             "losing the queen to a recapture is a large loss")
        XCTAssertEqual(queenGrab.judgment, .blunder)
        XCTAssertGreaterThanOrEqual(review.summary.blundersWhite, 1)
    }

    /// The evaluator reports White-perspective scores for both sides to move:
    /// a position where White is a queen up must stay strongly positive
    /// whether White or Black is on turn.
    func testScoresAreWhitePerspectiveForBothSides() {
        let whiteToMove = Board(fen: "4k3/8/8/8/8/8/8/QK6 w - - 0 1")!
        let blackToMove = Board(fen: "4k3/8/8/8/8/8/8/QK6 b - - 0 1")!
        XCTAssertGreaterThan(evaluator(whiteToMove).score, 500)
        XCTAssertGreaterThan(evaluator(blackToMove).score, 500)
    }

    /// End-to-end shape check on a clean game: timeline covers every position,
    /// losses stay within the cap, and reasonable opening moves aren't blunders.
    func testCleanOpeningProducesSaneReview() {
        let g = game(["e2e4", "e7e5", "g1f3", "b8c6", "f1b5", "a7a6"])
        let review = GameReview(analyzing: g, evaluator: evaluator)

        XCTAssertEqual(review.evalTimeline.count, g.moveCount + 1)
        XCTAssertEqual(review.moves.count, g.moveCount)
        for move in review.moves {
            XCTAssertGreaterThanOrEqual(move.centipawnLoss, 0)
            XCTAssertLessThanOrEqual(move.centipawnLoss, 1000)
            XCTAssertNotEqual(move.judgment, .blunder,
                              "\(move.san) is a mainline Ruy Lopez move")
        }
    }
}
