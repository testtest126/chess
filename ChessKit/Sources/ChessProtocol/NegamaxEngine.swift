import ChessKit

/// A small alpha-beta negamax search built on ChessKit's static ``Board/evaluate()``.
/// Not a competitive engine — it exists so the protocol layer has a real, deterministic
/// opponent and a reference implementation to validate the UCI adapter against.
public struct NegamaxEngine: ChessEngine {
    public let name: String
    public let author: String

    /// Score assigned to a checkmate at the root. Mates found deeper are worth
    /// slightly less so the search prefers the fastest one.
    static let mateScore = 1_000_000
    /// Scores at or beyond this magnitude are treated as forced mates.
    static let mateThreshold = mateScore - 1000

    public init(name: String = "ChessKit-Negamax", author: String = "ChessKit") {
        self.name = name
        self.author = author
    }

    public func search(_ board: Board, limit: SearchLimit) -> SearchResult {
        var nodes = 0

        /// Side-to-move-relative static evaluation.
        func staticEval(_ b: Board) -> Int {
            b.sideToMove == .white ? b.evaluate() : -b.evaluate()
        }

        /// Negamax with alpha-beta pruning. Returns a score from the perspective
        /// of `b`'s side to move. `ply` is the distance from the root.
        func negamax(_ b: Board, depth: Int, alpha: Int, beta: Int, ply: Int) -> Int {
            nodes += 1

            let moves = b.legalMoves()
            if moves.isEmpty {
                // Checkmate is bad for the side to move; stalemate is a draw.
                return b.isInCheck(b.sideToMove) ? -(Self.mateScore - ply) : 0
            }
            // Non-mating draws.
            if b.halfmoveClock >= 100 || b.hasInsufficientMaterial { return 0 }
            if depth == 0 { return staticEval(b) }
            if let cap = limit.maxNodes, nodes >= cap { return staticEval(b) }

            var best = Int.min + 1
            var a = alpha
            for move in moves {
                guard let next = b.making(move) else { continue }
                let score = -negamax(next, depth: depth - 1, alpha: -beta, beta: -a, ply: ply + 1)
                if score > best { best = score }
                if score > a { a = score }
                if a >= beta { break } // beta cutoff
            }
            return best
        }

        let rootMoves = board.legalMoves()
        guard !rootMoves.isEmpty else {
            // Terminal position: report the game-theoretic score, no move.
            let mated = board.isInCheck(board.sideToMove)
            return SearchResult(
                bestMove: nil,
                scoreCentipawns: mated ? -Self.mateScore : 0,
                mateInPlies: mated ? 0 : nil,
                depth: 0,
                nodes: 0
            )
        }

        let depth = max(1, limit.depth)
        var bestMove = rootMoves[0]
        var bestScore = Int.min + 1
        var alpha = Int.min + 1
        let beta = Int.max - 1

        for move in rootMoves {
            guard let next = board.making(move) else { continue }
            let score = -negamax(next, depth: depth - 1, alpha: -beta, beta: -alpha, ply: 1)
            if score > bestScore {
                bestScore = score
                bestMove = move
            }
            if score > alpha { alpha = score }
        }

        return SearchResult(
            bestMove: bestMove,
            scoreCentipawns: bestScore,
            mateInPlies: Self.matePlies(from: bestScore),
            depth: depth,
            nodes: nodes
        )
    }

    /// Converts a raw negamax score into plies-to-mate, or `nil` if not a mate.
    /// Positive = side to move delivers mate; negative = side to move gets mated.
    static func matePlies(from score: Int) -> Int? {
        if score >= mateThreshold { return mateScore - score }
        if score <= -mateThreshold { return -(mateScore + score) }
        return nil
    }
}
