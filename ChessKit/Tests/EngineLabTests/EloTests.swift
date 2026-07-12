import XCTest
@testable import EngineLab

final class EloTests: XCTestCase {
    func testEvenScoreIsZeroElo() {
        XCTAssertEqual(Elo.difference(forScore: 0.5), 0, accuracy: 1e-6)
    }

    func testKnownScoreConversions() {
        // -400·log10(1/0.75 − 1) ≈ 190.85; symmetric below 0.5.
        XCTAssertEqual(Elo.difference(forScore: 0.75), 190.85, accuracy: 0.5)
        XCTAssertEqual(Elo.difference(forScore: 0.25), -190.85, accuracy: 0.5)
    }

    func testMonotonicInScore() {
        XCTAssertLessThan(Elo.difference(forScore: 0.4), Elo.difference(forScore: 0.6))
        XCTAssertLessThan(Elo.difference(forScore: 0.6), Elo.difference(forScore: 0.9))
    }

    /// A clean sweep must not blow up to infinity — the score is clamped so the
    /// gap is large but finite.
    func testSweepsAreFinite() {
        XCTAssertTrue(Elo.difference(forScore: 1.0).isFinite)
        XCTAssertTrue(Elo.difference(forScore: 0.0).isFinite)
        XCTAssertGreaterThan(Elo.difference(forScore: 1.0), 400)
        XCTAssertLessThan(Elo.difference(forScore: 0.0), -400)
    }

    func testAllDrawsHaveZeroMargin() {
        // No variance in the outcomes ⇒ no uncertainty in the score.
        XCTAssertEqual(Elo.errorMargin95(wins: 0, draws: 20, losses: 0), 0, accuracy: 1e-9)
    }

    func testDecisiveResultsHavePositiveMargin() {
        XCTAssertGreaterThan(Elo.errorMargin95(wins: 10, draws: 0, losses: 10), 0)
    }

    /// More games at the same score ratio tighten the confidence interval.
    func testMarginShrinksWithMoreGames() {
        let few = Elo.errorMargin95(wins: 6, draws: 0, losses: 4)
        let many = Elo.errorMargin95(wins: 60, draws: 0, losses: 40)
        XCTAssertLessThan(many, few)
    }

    func testEmptyMatchIsZero() {
        XCTAssertEqual(Elo.errorMargin95(wins: 0, draws: 0, losses: 0), 0)
    }
}
