import Foundation
import ChessKit

/// An alpha-beta negamax search over ChessKit's evaluation, with iterative
/// deepening, a transposition table, MVV-LVA move ordering, check extensions,
/// and quiescence search. Deterministic when no node or time limit cuts the
/// search short and no opening book is attached.
public struct NegamaxEngine: ChessEngine {
    public let name: String
    public let author: String
    /// When set, positions found in the book are answered instantly with a
    /// (uniformly random) book move instead of searching.
    public let book: OpeningBook?

    /// Score assigned to a checkmate at the root. Mates found deeper are worth
    /// slightly less so the search prefers the fastest one.
    static let mateScore = 1_000_000
    /// Scores at or beyond this magnitude are treated as forced mates.
    static let mateThreshold = mateScore - 1000

    public init(
        name: String = "ChessKit-Negamax",
        author: String = "ChessKit",
        book: OpeningBook? = nil
    ) {
        self.name = name
        self.author = author
        self.book = book
    }

    public func search(_ board: Board, limit: SearchLimit) -> SearchResult {
        if let bookMove = book?.moves(for: board).randomElement(), board.isLegal(bookMove) {
            return SearchResult(bestMove: bookMove, scoreCentipawns: 0, depth: 0, nodes: 0)
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

        let search = Search(limit: limit)
        var orderedRoot = search.ordered(rootMoves, in: board, first: nil)
        var bestMove = orderedRoot[0]
        var bestScore = 0
        var completedDepth = 0

        // Iterative deepening: each pass reuses the previous best move for
        // ordering; an interrupted pass is discarded so the returned move is
        // always the product of a complete search.
        for depth in 1...max(1, limit.depth) {
            // The depth-1 pass always runs to completion so there is a move.
            search.abortAllowed = depth > 1

            var passBest: Move?
            var passScore = Int.min + 1
            var alpha = Int.min + 1
            let beta = Int.max - 1

            for move in orderedRoot {
                guard let next = board.making(move) else { continue }
                let score = -search.negamax(next, depth: depth - 1, alpha: -beta, beta: -alpha, ply: 1)
                if search.aborted { break }
                if score > passScore {
                    passScore = score
                    passBest = move
                }
                if score > alpha { alpha = score }
            }

            guard !search.aborted, let passMove = passBest else { break }
            bestMove = passMove
            bestScore = passScore
            completedDepth = depth

            // A forced mate for us can't improve; stop early. (A mate *against*
            // us is still worth deepening — a longer defense may exist.)
            if bestScore >= Self.mateThreshold { break }

            orderedRoot = search.ordered(rootMoves, in: board, first: passMove)
        }

        return SearchResult(
            bestMove: bestMove,
            scoreCentipawns: bestScore,
            mateInPlies: Self.matePlies(from: bestScore),
            depth: completedDepth,
            nodes: search.nodes
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

/// Mutable state for one `search` call: node counting, limit tracking, the
/// transposition table, and the recursive routines. Reference semantics keep
/// the hot path free of `inout`.
private final class Search {
    var nodes = 0
    var aborted = false
    /// The depth-1 pass runs with aborts disabled so a move always comes back.
    var abortAllowed = false

    /// A line may extend at most this many times (check extensions), so
    /// perpetual-check lines can't recurse unboundedly.
    private static let maxExtensions = 8
    /// Entry cap so pathological searches can't grow memory without bound.
    private static let maxTableEntries = 2_000_000

    private enum Bound {
        case exact, lower, upper
    }

    private struct TTEntry {
        let depth: Int
        /// Mate scores are stored relative to the entry's node (see
        /// `storeScore`/`probeScore`) so they stay correct at any ply.
        let score: Int
        let bound: Bound
        let move: Move?
    }

    private var table: [UInt64: TTEntry] = [:]

    private let maxNodes: Int?
    private let deadline: ContinuousClock.Instant?

    init(limit: SearchLimit) {
        self.maxNodes = limit.maxNodes
        self.deadline = limit.moveTime.map { ContinuousClock.now + .seconds($0) }
    }

    /// Checks limits (time only every 1024 nodes — clock reads aren't free).
    private func checkAbort() -> Bool {
        if aborted { return true }
        guard abortAllowed else { return false }
        if let maxNodes, nodes >= maxNodes {
            aborted = true
        } else if nodes & 1023 == 0, let deadline, ContinuousClock.now >= deadline {
            aborted = true
        }
        return aborted
    }

    private func staticEval(_ b: Board) -> Int {
        b.sideToMove == .white ? b.evaluate() : -b.evaluate()
    }

    /// Move ordering: `first` (previous iteration's best), then promotions and
    /// captures by MVV-LVA, then quiet moves in generation order.
    func ordered(_ moves: [Move], in board: Board, first: Move?) -> [Move] {
        func priority(_ move: Move) -> Int {
            if move == first { return .max }
            var score = 0
            if let promotion = move.promotion {
                score += 10_000 + promotion.centipawnValue
            }
            if let victim = board[move.to] {
                let attacker = board[move.from]?.kind.centipawnValue ?? 0
                score += 1_000 + victim.kind.centipawnValue * 10 - attacker
            } else if board[move.from]?.kind == .pawn, move.to == board.enPassantSquare {
                score += 1_000 + PieceKind.pawn.centipawnValue * 10 - PieceKind.pawn.centipawnValue
            }
            return score
        }
        // Stable order for determinism: sort by (priority desc, original index).
        return moves.enumerated()
            .sorted { a, b in
                let (pa, pb) = (priority(a.element), priority(b.element))
                return pa != pb ? pa > pb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// Negamax with alpha-beta and transposition table. Returns a score from
    /// the perspective of `b`'s side to move. `ply` is the distance from the
    /// root. Meaningless once `aborted` is set — callers must check.
    func negamax(_ b: Board, depth: Int, alpha: Int, beta: Int, ply: Int, extensions: Int = 0) -> Int {
        nodes += 1
        if checkAbort() { return 0 }

        let moves = b.legalMoves()
        if moves.isEmpty {
            return b.isInCheck(b.sideToMove) ? -(NegamaxEngine.mateScore - ply) : 0
        }
        if b.halfmoveClock >= 100 || b.hasInsufficientMaterial { return 0 }

        // Check extension: dangerous positions deserve one extra ply.
        var depth = depth
        var extensions = extensions
        if extensions < Self.maxExtensions, b.isInCheck(b.sideToMove) {
            depth += 1
            extensions += 1
        }
        if depth == 0 {
            return quiesce(b, alpha: alpha, beta: beta, ply: ply, moves: moves)
        }

        // Transposition table probe: reuse an earlier visit of this position
        // if it searched at least as deep; otherwise keep its best move for
        // ordering.
        let key = Zobrist.key(for: b)
        var ttMove: Move?
        if let entry = table[key] {
            ttMove = entry.move
            if entry.depth >= depth {
                let score = Self.probeScore(entry.score, ply: ply)
                switch entry.bound {
                case .exact:
                    return score
                case .lower:
                    if score >= beta { return score }
                case .upper:
                    if score <= alpha { return score }
                }
            }
        }

        var best = Int.min + 1
        var bestMove: Move?
        var a = alpha
        for move in ordered(moves, in: b, first: ttMove) {
            guard let next = b.making(move) else { continue }
            let score = -negamax(next, depth: depth - 1, alpha: -beta, beta: -a, ply: ply + 1, extensions: extensions)
            if aborted { return 0 }
            if score > best {
                best = score
                bestMove = move
            }
            if score > a { a = score }
            if a >= beta { break } // beta cutoff
        }

        if table.count < Self.maxTableEntries {
            let bound: Bound = best >= beta ? .lower : (best <= alpha ? .upper : .exact)
            table[key] = TTEntry(
                depth: depth,
                score: Self.storeScore(best, ply: ply),
                bound: bound,
                move: bestMove
            )
        }
        return best
    }

    /// Mate scores are ply-relative to the root; convert to node-relative on
    /// store and back on probe so a mate found via one path scores correctly
    /// when the position is reached at a different ply.
    private static func storeScore(_ score: Int, ply: Int) -> Int {
        if score >= NegamaxEngine.mateThreshold { return score + ply }
        if score <= -NegamaxEngine.mateThreshold { return score - ply }
        return score
    }

    private static func probeScore(_ score: Int, ply: Int) -> Int {
        if score >= NegamaxEngine.mateThreshold { return score - ply }
        if score <= -NegamaxEngine.mateThreshold { return score + ply }
        return score
    }

    /// Quiescence: at the horizon, keep resolving captures and promotions so
    /// the static evaluation is never taken in the middle of an exchange.
    /// In check there is no standing pat — every evasion is searched.
    private func quiesce(_ b: Board, alpha: Int, beta: Int, ply: Int, moves: [Move]) -> Int {
        nodes += 1
        if checkAbort() { return 0 }

        if moves.isEmpty {
            return b.isInCheck(b.sideToMove) ? -(NegamaxEngine.mateScore - ply) : 0
        }
        if b.halfmoveClock >= 100 || b.hasInsufficientMaterial { return 0 }

        let inCheck = b.isInCheck(b.sideToMove)
        var a = alpha
        var best: Int
        let candidates: [Move]

        if inCheck {
            // A checked side can't decline to respond; consider all evasions.
            best = Int.min + 1
            candidates = moves
        } else {
            // Stand pat: the side to move may decline all captures.
            let standPat = staticEval(b)
            if standPat >= beta { return standPat }
            a = max(a, standPat)
            best = standPat
            candidates = moves.filter { move in
                if b[move.to] != nil || move.promotion != nil { return true }
                return b[move.from]?.kind == .pawn && move.to == b.enPassantSquare
            }
        }

        for move in ordered(candidates, in: b, first: nil) {
            guard let next = b.making(move) else { continue }
            let score = -quiesce(next, alpha: -beta, beta: -a, ply: ply + 1, moves: next.legalMoves())
            if aborted { return 0 }
            if score > best { best = score }
            if score > a { a = score }
            if a >= beta { break }
        }
        return best
    }
}
