import Foundation
import ChessKit

/// Constraints on a single search. Mirrors the subset of UCI `go` parameters
/// the built-in engine understands.
public struct SearchLimit: Sendable, Equatable {
    /// Maximum search depth in plies. Always honored by the built-in engine.
    public var depth: Int
    /// Optional soft cap on nodes visited. `nil` means no node limit.
    public var maxNodes: Int?
    /// Optional soft time budget in seconds. The engine finishes the depth-1
    /// pass regardless, then stops deepening once the budget is spent, so it
    /// always returns a fully searched move.
    public var moveTime: TimeInterval?

    public init(depth: Int, maxNodes: Int? = nil, moveTime: TimeInterval? = nil) {
        self.depth = depth
        self.maxNodes = maxNodes
        self.moveTime = moveTime
    }

    public static let `default` = SearchLimit(depth: 4)
}

/// The outcome of a search from a single root position.
public struct SearchResult: Sendable, Equatable {
    /// Best move found, or `nil` if the position is terminal (no legal moves).
    public var bestMove: Move?
    /// Score in centipawns from the side-to-move's perspective (UCI convention).
    public var scoreCentipawns: Int
    /// Number of plies until a forced mate, positive if the side to move is
    /// mating, negative if being mated. `nil` when no mate is seen.
    public var mateInPlies: Int?
    /// Depth actually searched.
    public var depth: Int
    /// Total nodes visited.
    public var nodes: Int

    public init(
        bestMove: Move?,
        scoreCentipawns: Int,
        mateInPlies: Int? = nil,
        depth: Int,
        nodes: Int
    ) {
        self.bestMove = bestMove
        self.scoreCentipawns = scoreCentipawns
        self.mateInPlies = mateInPlies
        self.depth = depth
        self.nodes = nodes
    }
}

/// A move-picking engine over ChessKit positions. Implementations range from the
/// built-in ``NegamaxEngine`` heuristic search to an external UCI process later.
public protocol ChessEngine: Sendable {
    /// Human-readable engine name, reported in the UCI `id name` line.
    var name: String { get }
    /// Engine author, reported in the UCI `id author` line.
    var author: String { get }

    /// Searches `board` under `limit` and returns the best move and evaluation.
    func search(_ board: Board, limit: SearchLimit) -> SearchResult
}

public extension ChessEngine {
    /// Convenience: the best move under the default limit, or `nil` if terminal.
    func bestMove(in board: Board) -> Move? {
        search(board, limit: .default).bestMove
    }
}
