import ChessKit
import ChessProtocol

/// Material count only — no piece-square tables. A deliberately weaker
/// reference evaluator, useful two ways: it exercises the ``PositionEvaluator``
/// seam with something that actually differs from ``DefaultEvaluator`` (proving
/// the seam changes real search behavior, not just compiling), and it gives the
/// A/B harness a concrete, fast, always-available comparison — "does the
/// shipping evaluator's piece-square scoring actually help?" — without needing
/// a not-yet-merged candidate evaluator to point at.
///
/// Lives in `EngineLab` (measurement-only, never linked into the app), not in
/// `ChessKit`/`ChessProtocol` — an experimental evaluator variant has no
/// business in the shipping engine path.
public struct MaterialOnlyEvaluator: PositionEvaluator {
    public init() {}

    public func evaluate(_ board: Board) -> Int {
        var score = 0
        for square in 0..<64 {
            guard let piece = board[square] else { continue }
            let value = piece.kind.centipawnValue
            score += piece.color == .white ? value : -value
        }
        return score
    }
}
