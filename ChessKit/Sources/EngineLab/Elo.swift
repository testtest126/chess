import Foundation

/// Elo arithmetic for match results.
///
/// The logistic (Elo) model maps a rating difference to an expected score:
/// `E = 1 / (1 + 10^(-Δ/400))`. Inverting it turns an observed score fraction
/// back into the rating difference it implies. The error margin comes from the
/// binomial/trinomial spread of the actual W/D/L sample, so it is exact for the
/// (fixed, reproducible) games that were played.
public enum Elo {
    /// 95% two-sided normal quantile.
    static let z95 = 1.959963984540054

    /// Score fractions are clamped this far from 0 and 1 before inversion so a
    /// clean sweep reports a large-but-finite rating gap instead of infinity.
    static let scoreEpsilon = 0.5 / 1000.0

    /// The rating difference implied by an expected score in (0, 1). Positive
    /// when `score > 0.5`.
    public static func difference(forScore score: Double) -> Double {
        let s = min(1 - scoreEpsilon, max(scoreEpsilon, score))
        return -400 * log10(1 / s - 1)
    }

    /// 95% confidence half-width (in Elo) around the point estimate, derived
    /// from the standard error of the observed score.
    public static func errorMargin95(wins: Int, draws: Int, losses: Int) -> Double {
        let n = wins + draws + losses
        guard n > 0 else { return 0 }
        let total = Double(n)
        let score = (Double(wins) + 0.5 * Double(draws)) / total

        // Sample variance of a single game's points (1 / 0.5 / 0), then the
        // standard error of the mean over n games.
        let variance =
            (Double(wins) * pow(1 - score, 2)
                    + Double(draws) * pow(0.5 - score, 2)
                    + Double(losses) * pow(0 - score, 2)) / total
        let standardError = (variance / total).squareRoot()

        let low = difference(forScore: score - z95 * standardError)
        let high = difference(forScore: score + z95 * standardError)
        return (high - low) / 2
    }
}
