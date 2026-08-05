import ChessKit
import ChessProtocol
import XCTest
@testable import EngineLab

final class ABTestTests: XCTestCase {
    /// A tolerant, easy-to-cross SPRT so cheap depth-1 tests can actually
    /// reach a verdict instead of exhausting the whole schedule.
    let looseSPRT = SPRT.Parameters(elo0: -30, elo1: 30, alpha: 0.1, beta: 0.1)

    /// Identical configs (including the same evaluator) must net exactly even
    /// — the same color-swap fairness guarantee ``SelfPlay`` has, now
    /// exercised through the evaluator seam instead of only through search
    /// limits.
    func testIdenticalEvaluatorsNetEven() {
        let config = EngineConfig(label: "same", limit: SearchLimit(depth: 1), evaluator: DefaultEvaluator())
        let openings = Array(Openings.standard.prefix(2))
        let abConfig = ABTestConfig(
            baseline: config, candidate: config, openings: openings, maxPlies: 80, sprt: looseSPRT
        )
        let result = ABTest.run(abConfig)

        XCTAssertEqual(result.wins, result.losses, "identical evaluators must net even")
        XCTAssertEqual(result.scoreCandidate, 0.5, accuracy: 1e-9)
        XCTAssertEqual(result.eloDelta, 0, accuracy: 1e-6)
        XCTAssertEqual(result.sprt.decision, .continueTesting, "a dead-even result shouldn't accept either hypothesis")
        XCTAssertNil(result.sprtDecidedAtGame)
        XCTAssertEqual(result.gamesPlayed, openings.count * 2)
    }

    /// The evaluator seam actually drives the result: a candidate missing
    /// piece-square tables should score below 50% against the PST-aware
    /// baseline, at a search depth deep enough for the evaluation (not raw
    /// tactics) to dominate most of these quiet openings.
    func testMaterialOnlyCandidateScoresBelowBaseline() {
        let baseline = EngineConfig(label: "baseline", limit: SearchLimit(depth: 1), evaluator: DefaultEvaluator())
        let candidate = EngineConfig(label: "candidate", limit: SearchLimit(depth: 1), evaluator: MaterialOnlyEvaluator())
        let openings = Array(Openings.standard.prefix(4))
        let abConfig = ABTestConfig(
            baseline: baseline, candidate: candidate, openings: openings, maxPlies: 60, sprt: looseSPRT
        )
        let result = ABTest.run(abConfig)

        XCTAssertLessThan(result.scoreCandidate, 0.5, "dropping PST should not outscore the baseline")
        XCTAssertLessThan(result.eloDelta, 0)
    }

    /// SPRT actually stops the run early when the evidence is one-sided
    /// enough — the headline feature over the old fixed-game-count harness.
    func testSPRTStopsBeforeExhaustingTheSchedule() {
        let baseline = EngineConfig(label: "baseline", limit: SearchLimit(depth: 1), evaluator: DefaultEvaluator())
        let candidate = EngineConfig(label: "candidate", limit: SearchLimit(depth: 1), evaluator: MaterialOnlyEvaluator())
        let openings = Openings.standard
        let fullSchedule = openings.count * 2
        let abConfig = ABTestConfig(
            baseline: baseline, candidate: candidate, openings: openings, maxPlies: 60, sprt: looseSPRT
        )
        let result = ABTest.run(abConfig)

        guard let decidedAt = result.sprtDecidedAtGame else {
            XCTFail("expected the loose SPRT to resolve against a materially worse candidate")
            return
        }
        XCTAssertLessThan(decidedAt, fullSchedule, "should stop before playing every scheduled game")
        XCTAssertEqual(result.gamesPlayed, decidedAt)
        XCTAssertNotEqual(result.sprt.decision, .continueTesting)
    }

    /// `maxGames` caps the schedule even if SPRT never resolves.
    func testMaxGamesCapsTheSchedule() {
        let config = EngineConfig(label: "same", limit: SearchLimit(depth: 1))
        // A razor-tight SPRT that a dead-even match will never satisfy.
        let unwinnableSPRT = SPRT.Parameters(elo0: 0, elo1: 1, alpha: 0.001, beta: 0.001)
        let abConfig = ABTestConfig(
            baseline: config, candidate: config, openings: Openings.standard, maxPlies: 60,
            sprt: unwinnableSPRT, maxGames: 3
        )
        let result = ABTest.run(abConfig)
        XCTAssertEqual(result.gamesPlayed, 3)
        XCTAssertNil(result.sprtDecidedAtGame)
    }

    /// Full determinism: rerunning the exact same config reproduces every
    /// game record, not just the aggregate totals.
    func testRunIsFullyDeterministic() {
        let baseline = EngineConfig(label: "baseline", limit: SearchLimit(depth: 1), evaluator: DefaultEvaluator())
        let candidate = EngineConfig(label: "candidate", limit: SearchLimit(depth: 1), evaluator: MaterialOnlyEvaluator())
        let abConfig = ABTestConfig(
            baseline: baseline, candidate: candidate,
            openings: Array(Openings.standard.prefix(3)), maxPlies: 60, sprt: looseSPRT
        )

        let first = ABTest.run(abConfig)
        let second = ABTest.run(abConfig)

        XCTAssertEqual(first.wins, second.wins)
        XCTAssertEqual(first.draws, second.draws)
        XCTAssertEqual(first.losses, second.losses)
        XCTAssertEqual(first.sprt.llr, second.sprt.llr)
        XCTAssertEqual(first.sprt.decision, second.sprt.decision)
        XCTAssertEqual(first.sprtDecidedAtGame, second.sprtDecidedAtGame)
        XCTAssertEqual(first.games, second.games)
    }

    /// The harness reports its own effective sample size and W/D/L honestly:
    /// they must always add up.
    func testTotalsAreConsistent() {
        let config = EngineConfig(label: "same", limit: SearchLimit(depth: 1))
        let abConfig = ABTestConfig(
            baseline: config, candidate: config,
            openings: Array(Openings.standard.prefix(2)), maxPlies: 60, sprt: looseSPRT
        )
        let result = ABTest.run(abConfig)
        XCTAssertEqual(result.wins + result.draws + result.losses, result.gamesPlayed)
        XCTAssertEqual(result.games.count, result.gamesPlayed)
    }
}
