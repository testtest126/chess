import ChessKit

/// A pluggable static position evaluator: centipawns from White's perspective,
/// for a position already known to be non-terminal (mirrors the contract of
/// ``Board/evaluateFast()``). ``NegamaxEngine`` calls this once per leaf node
/// via its quiescence stand-pat — the *only* place static evaluation happens
/// in the search — so a conforming type has full control over move selection
/// without touching search code.
///
/// This exists so a candidate evaluation function can be measured (see
/// `EngineLab`'s A/B harness) by passing a different ``PositionEvaluator`` to
/// ``NegamaxEngine``'s initializer, instead of a mutable global switch: each
/// engine instance is independently and deterministically wired to the
/// evaluator it was built with, so two configurations can run concurrently
/// (or interleaved) with no shared, mutable state between them.
public protocol PositionEvaluator: Sendable {
    func evaluate(_ board: Board) -> Int
}

/// The engine's shipping evaluator: `Board.evaluateFast()` unchanged. Every
/// production caller (the app, UCI, `PersistentNegamaxEngine`) gets exactly
/// this when it doesn't specify one, so adding the seam is behavior-neutral.
public struct DefaultEvaluator: PositionEvaluator {
    public init() {}

    public func evaluate(_ board: Board) -> Int {
        board.evaluateFast()
    }
}
