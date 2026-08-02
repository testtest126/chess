import Foundation

/// Sequential Probability Ratio Test for engine-strength A/B measurement, in
/// the style used by chess-engine testing frameworks (fishtest, cutechess-cli
/// `--sprt`): test H0 ("candidate is no better than `elo0`") against H1
/// ("candidate is at least `elo1` stronger"), and let a long run of decisive
/// results reach a confident stop well before a fixed game budget would.
///
/// Simplification, stated plainly: a game's expected score at rating
/// difference `E` is the logistic `p(E) = 1 / (1 + 10^(-E/400))`. Splitting
/// that into win/draw/loss probabilities needs a draw-rate model; this one
/// holds a single assumed draw probability `d` fixed under *both* hypotheses
/// (`SPRTParameters.assumedDrawProbability`) and gives the rest of the mass to
/// win/loss according to `p(elo0)`/`p(elo1)`. Because `d` is shared, **draws
/// contribute zero to the log-likelihood ratio** — only decisive games move
/// it. This is an approximation of the full pentanomial/pairs-based GSPRT
/// fishtest actually runs (which lets the draw rate itself carry information
/// and pairs games by opening for variance reduction); it does not require
/// estimating extra parameters, and is exact for the two-hypothesis test as
/// long as the constant-`d` assumption holds.
public enum SPRT {
    /// `elo0`/`elo1` bound the two hypotheses (H0: true Elo ≤ elo0, H1: true
    /// Elo ≥ elo1); `alpha`/`beta` are the Wald test's type-I/type-II error
    /// rates. `assumedDrawProbability` must be small enough that both
    /// win/loss probabilities stay non-negative at both `elo0` and `elo1` —
    /// `isValid` reports that.
    public struct Parameters: Sendable {
        public let elo0: Double
        public let elo1: Double
        public let alpha: Double
        public let beta: Double
        public let assumedDrawProbability: Double

        public init(elo0: Double, elo1: Double, alpha: Double = 0.05, beta: Double = 0.05, assumedDrawProbability: Double = 0.5) {
            precondition(elo1 > elo0, "elo1 must exceed elo0")
            precondition(alpha > 0 && alpha < 1, "alpha must be in (0, 1)")
            precondition(beta > 0 && beta < 1, "beta must be in (0, 1)")
            self.elo0 = elo0
            self.elo1 = elo1
            self.alpha = alpha
            self.beta = beta
            self.assumedDrawProbability = assumedDrawProbability
        }

        /// The Wald upper bound: LLR at or above this accepts H1.
        public var upperBound: Double { log((1 - beta) / alpha) }
        /// The Wald lower bound: LLR at or below this accepts H0.
        public var lowerBound: Double { log(beta / (1 - alpha)) }

        /// False when `assumedDrawProbability` is too large for `elo0`/`elo1`
        /// to produce non-negative win/loss probabilities.
        public var isValid: Bool {
            outcomeProbabilities(elo0).isValid && outcomeProbabilities(elo1).isValid
        }

        /// Win/draw/loss probabilities implied by a hypothesis's Elo and the
        /// shared assumed draw probability.
        func outcomeProbabilities(_ elo: Double) -> (win: Double, draw: Double, loss: Double, isValid: Bool) {
            let expectedScore = 1 / (1 + pow(10, -elo / 400))
            let win = expectedScore - assumedDrawProbability / 2
            let loss = 1 - expectedScore - assumedDrawProbability / 2
            return (win, assumedDrawProbability, loss, win >= 0 && loss >= 0)
        }
    }

    public enum Decision: String, Sendable, Equatable {
        /// H1 accepted: the data supports "candidate is at least `elo1`
        /// stronger" over "candidate is no better than `elo0`".
        case acceptH1 = "H1 accepted — candidate is an improvement"
        /// H0 accepted: the data supports "candidate is no better than
        /// `elo0`" over the stronger hypothesis.
        case acceptH0 = "H0 accepted — candidate is not an improvement"
        /// Neither bound crossed yet; more games would sharpen the answer.
        case continueTesting = "inconclusive — keep playing"
    }

    public struct Result: Sendable {
        public let llr: Double
        public let lowerBound: Double
        public let upperBound: Double
        public let decision: Decision
    }

    /// Evaluates the test against cumulative W/D/L counts (candidate's
    /// perspective). Stateless by design — call it after every game with the
    /// running totals; there is nothing to carry between calls.
    public static func evaluate(wins: Int, draws: Int, losses: Int, parameters: Parameters) -> Result {
        let p0 = parameters.outcomeProbabilities(parameters.elo0)
        let p1 = parameters.outcomeProbabilities(parameters.elo1)

        // Draws drop out: log(p1.draw / p0.draw) = log(d / d) = 0, since both
        // hypotheses share the same assumed draw probability.
        let llrPerWin = log(p1.win / p0.win)
        let llrPerLoss = log(p1.loss / p0.loss)
        let llr = Double(wins) * llrPerWin + Double(losses) * llrPerLoss

        let upper = parameters.upperBound
        let lower = parameters.lowerBound
        let decision: Decision
        if llr >= upper {
            decision = .acceptH1
        } else if llr <= lower {
            decision = .acceptH0
        } else {
            decision = .continueTesting
        }
        return Result(llr: llr, lowerBound: lower, upperBound: upper, decision: decision)
    }
}
