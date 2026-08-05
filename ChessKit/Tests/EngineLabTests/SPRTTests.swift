import XCTest
@testable import EngineLab

final class SPRTTests: XCTestCase {
    let params = SPRT.Parameters(elo0: 0, elo1: 10, alpha: 0.05, beta: 0.05, assumedDrawProbability: 0.5)

    func testNoGamesIsInconclusive() {
        let result = SPRT.evaluate(wins: 0, draws: 0, losses: 0, parameters: params)
        XCTAssertEqual(result.llr, 0, accuracy: 1e-9)
        XCTAssertEqual(result.decision, .continueTesting)
    }

    /// A long run of nothing but wins must eventually cross the upper bound —
    /// the defining "stop early when confident" property of SPRT.
    func testManyWinsEventuallyAcceptsH1() {
        var wins = 0
        var decision = SPRT.Decision.continueTesting
        while decision == .continueTesting && wins < 1000 {
            wins += 1
            decision = SPRT.evaluate(wins: wins, draws: 0, losses: 0, parameters: params).decision
        }
        XCTAssertEqual(decision, .acceptH1)
        XCTAssertLessThan(wins, 1000, "should resolve well before the safety cap")
    }

    /// Symmetric to the above: a long run of nothing but losses must cross
    /// the lower bound.
    func testManyLossesEventuallyAcceptsH0() {
        var losses = 0
        var decision = SPRT.Decision.continueTesting
        while decision == .continueTesting && losses < 1000 {
            losses += 1
            decision = SPRT.evaluate(wins: 0, draws: 0, losses: losses, parameters: params).decision
        }
        XCTAssertEqual(decision, .acceptH0)
        XCTAssertLessThan(losses, 1000)
    }

    /// An even split of wins and losses at a modest sample size shouldn't
    /// convince the test of either extreme.
    func testEvenSplitStaysInconclusiveAtSmallSample() {
        let result = SPRT.evaluate(wins: 10, draws: 0, losses: 10, parameters: params)
        XCTAssertEqual(result.decision, .continueTesting)
    }

    /// Draws are modeled as equally likely under both hypotheses (shared
    /// `assumedDrawProbability`), so they must not move the LLR at all —
    /// the central simplification this SPRT variant makes, and the one
    /// property that most needs a pinned test.
    func testDrawsContributeNothingToLLR() {
        let fewDraws = SPRT.evaluate(wins: 5, draws: 0, losses: 5, parameters: params)
        let manyDraws = SPRT.evaluate(wins: 5, draws: 50, losses: 5, parameters: params)
        XCTAssertEqual(fewDraws.llr, manyDraws.llr, accuracy: 1e-9)
    }

    /// The LLR is monotonic in wins (more wins ⇒ higher LLR, moving toward H1)
    /// and in losses in the opposite direction — the sign convention a caller
    /// depends on to read "which way is the evidence pointing".
    func testLLRMonotonicity() {
        let base = SPRT.evaluate(wins: 5, draws: 0, losses: 5, parameters: params)
        let moreWins = SPRT.evaluate(wins: 6, draws: 0, losses: 5, parameters: params)
        let moreLosses = SPRT.evaluate(wins: 5, draws: 0, losses: 6, parameters: params)
        XCTAssertGreaterThan(moreWins.llr, base.llr)
        XCTAssertLessThan(moreLosses.llr, base.llr)
    }

    /// Tightening alpha/beta (more caution against a wrong call) must widen
    /// both bounds — the Wald-test relationship between error tolerance and
    /// the evidence required to stop.
    func testTighterErrorRatesWidenBounds() {
        let loose = SPRT.Parameters(elo0: 0, elo1: 10, alpha: 0.1, beta: 0.1)
        let tight = SPRT.Parameters(elo0: 0, elo1: 10, alpha: 0.01, beta: 0.01)
        XCTAssertGreaterThan(tight.upperBound, loose.upperBound)
        XCTAssertLessThan(tight.lowerBound, loose.lowerBound)
    }

    /// Deterministic replay: the same W/D/L totals always produce the exact
    /// same verdict (no hidden state, no randomness).
    func testEvaluateIsDeterministic() {
        let a = SPRT.evaluate(wins: 7, draws: 3, losses: 2, parameters: params)
        let b = SPRT.evaluate(wins: 7, draws: 3, losses: 2, parameters: params)
        XCTAssertEqual(a.llr, b.llr)
        XCTAssertEqual(a.decision, b.decision)
    }

    func testParametersValidityFlagsExcessiveDrawProbability() {
        // At elo0 = -800, the expected score is tiny; a draw probability of
        // 0.9 leaves no room for a non-negative loss probability.
        let invalid = SPRT.Parameters(elo0: -800, elo1: 0, assumedDrawProbability: 0.9)
        XCTAssertFalse(invalid.isValid)

        let valid = SPRT.Parameters(elo0: 0, elo1: 10, assumedDrawProbability: 0.5)
        XCTAssertTrue(valid.isValid)
    }
}
