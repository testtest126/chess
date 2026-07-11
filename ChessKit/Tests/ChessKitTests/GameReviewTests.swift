import XCTest
@testable import ChessKit

final class GameReviewTests: XCTestCase {
    private func game(_ ucis: [String]) -> Game {
        var g = Game()
        for uci in ucis { try! g.play(uci: uci) }
        return g
    }

    func testTimelineAndCountsAreConsistent() {
        let g = game(["e2e4", "e7e5", "g1f3", "b8c6", "f1b5", "a7a6"])
        let review = GameReview(analyzing: g)
        XCTAssertEqual(review.evalTimeline.count, g.moveCount + 1)
        XCTAssertEqual(review.moves.count, g.history.count)
        for m in review.moves {
            XCTAssertGreaterThanOrEqual(m.centipawnLoss, 0)
            XCTAssertLessThanOrEqual(m.centipawnLoss, 1000)
        }
    }

    func testAccuracyWithinBounds() {
        let review = GameReview(analyzing: game(["e2e4", "e7e5", "g1f3", "b8c6"]))
        for acc in [review.summary.accuracyWhite, review.summary.accuracyBlack] {
            XCTAssertGreaterThanOrEqual(acc, 0)
            XCTAssertLessThanOrEqual(acc, 100)
        }
    }

    func testDecliningAFreeCaptureIsFlagged() {
        // White's rook on d1 can win the black queen on d4 with Rxd4. The 1-ply
        // review evaluator sees this best line, so playing the quiet Kf1 instead
        // is a large centipawn loss and should be judged a blunder.
        var g = try! Game(fen: "4k3/8/8/8/3q4/8/8/3RK3 w - - 0 1")
        try! g.play(uci: "e1f1") // declines Rxd4
        let review = GameReview(analyzing: g)
        let blunder = review.moves[0]
        XCTAssertEqual(blunder.mover, .white)
        XCTAssertEqual(blunder.san, "Kf1")
        XCTAssertGreaterThan(blunder.centipawnLoss, 250)
        XCTAssertEqual(blunder.judgment, .blunder)
        XCTAssertGreaterThanOrEqual(review.summary.blundersWhite, 1)
        // The review names the move that should have been played.
        XCTAssertEqual(blunder.bestSAN, "Rxd4")
    }

    func testCustomEvaluatorAndProgress() {
        let g = game(["e2e4", "e7e5", "g1f3", "b8c6"])
        var evaluated = 0
        var fractions: [Double] = []
        let review = GameReview(
            analyzing: g,
            evaluator: { _ in evaluated += 1; return GameReview.PositionAssessment(score: 0) },
            progress: { fractions.append($0) }
        )
        // Every position (initial + one per ply) evaluated exactly once.
        XCTAssertEqual(evaluated, g.moveCount + 1)
        XCTAssertEqual(fractions.count, g.moveCount + 1)
        XCTAssertEqual(fractions.last, 1.0)
        // A constant evaluator means nobody ever loses centipawns.
        XCTAssertTrue(review.moves.allSatisfy { $0.centipawnLoss == 0 })
        // The Lichess-style accuracy curve tops out just below 100 at 0 ACL.
        XCTAssertGreaterThan(review.summary.accuracyWhite, 99)
    }

    func testJudgmentThresholds() {
        XCTAssertEqual(GameReview.Judgment(centipawnLoss: 0), .best)
        XCTAssertEqual(GameReview.Judgment(centipawnLoss: 40), .good)
        XCTAssertEqual(GameReview.Judgment(centipawnLoss: 100), .inaccuracy)
        XCTAssertEqual(GameReview.Judgment(centipawnLoss: 200), .mistake)
        XCTAssertEqual(GameReview.Judgment(centipawnLoss: 500), .blunder)
    }
}
