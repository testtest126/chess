import Foundation
import ChessKit

/// An alpha-beta negamax search over ChessKit's evaluation, with iterative
/// deepening, aspiration windows, a transposition table, null-move pruning,
/// MVV-LVA + killer + history move ordering, check extensions, and quiescence
/// search. Deterministic when no node or time limit cuts the search short and
/// no opening book is attached.
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
        search(board, limit: limit, session: Search(limit: limit))
    }

    /// The full search driver, parameterized on the mutable session so
    /// ``PersistentNegamaxEngine`` can inject one whose transposition table
    /// survives across calls. The public `search` always passes a fresh
    /// session, keeping the value-type engine deterministic.
    func search(_ board: Board, limit: SearchLimit, session search: Search) -> SearchResult {
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

        var orderedRoot = search.ordered(rootMoves, in: board, first: nil, ply: 0)
        var bestMove = orderedRoot[0]
        var bestScore = 0
        var completedDepth = 0

        // Iterative deepening: each pass reuses the previous best move for
        // ordering and searches inside an aspiration window around the
        // previous score; an interrupted pass is discarded so the returned
        // move is always the product of a complete search.
        for depth in 1...max(1, limit.depth) {
            // The depth-1 pass always runs to completion so there is a move.
            search.abortAllowed = depth > 1

            var window = 50
            var alpha = depth > 1 ? bestScore - window : Int.min + 1
            var beta = depth > 1 ? bestScore + window : Int.max - 1
            var passBest: Move?
            var passScore = 0

            while true {
                (passBest, passScore) = rootPass(
                    board, moves: orderedRoot, depth: depth,
                    alpha: alpha, beta: beta, search: search
                )
                if search.aborted { break }
                // Fail low/high: the true score fell outside the aspiration
                // window; widen on the failing side and re-search.
                if passScore <= alpha {
                    window *= 4
                    alpha = passScore - window
                } else if passScore >= beta {
                    window *= 4
                    beta = passScore + window
                } else {
                    break
                }
            }

            guard !search.aborted, let passMove = passBest else { break }
            bestMove = passMove
            bestScore = passScore
            completedDepth = depth

            // A forced mate for us can't improve; stop early. (A mate *against*
            // us is still worth deepening — a longer defense may exist.)
            if bestScore >= Self.mateThreshold { break }

            orderedRoot = search.ordered(rootMoves, in: board, first: passMove, ply: 0)
        }

        return SearchResult(
            bestMove: bestMove,
            scoreCentipawns: bestScore,
            mateInPlies: Self.matePlies(from: bestScore),
            depth: completedDepth,
            nodes: search.nodes
        )
    }

    /// One full-width pass over the root moves inside an (alpha, beta) window.
    private func rootPass(
        _ board: Board, moves: [Move], depth: Int,
        alpha initialAlpha: Int, beta: Int, search: Search
    ) -> (Move?, Int) {
        var best: Move?
        var bestScore = Int.min + 1
        var alpha = initialAlpha

        for move in moves {
            guard let next = board.making(move) else { continue }
            let score = -search.negamax(next, depth: depth - 1, alpha: -beta, beta: -alpha, ply: 1)
            if search.aborted { return (nil, 0) }
            if score > bestScore {
                bestScore = score
                best = move
            }
            if score > alpha { alpha = score }
            if alpha >= beta { break }
        }
        return (best, bestScore)
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
/// transposition table, killer/history ordering data, and the recursive
/// routines. Reference semantics keep the hot path free of `inout`.
///
/// The transposition table can be seeded from a previous session (and read
/// back afterwards) so ``PersistentNegamaxEngine`` can carry it across moves;
/// killers and history stay per-session because their ply indexing is only
/// meaningful relative to one root.
final class Search {
    var nodes = 0
    var aborted = false
    /// The depth-1 pass runs with aborts disabled so a move always comes back.
    var abortAllowed = false

    /// A line may extend at most this many times (check extensions), so
    /// perpetual-check lines can't recurse unboundedly.
    private static let maxExtensions = 8
    /// Entry cap so pathological searches can't grow memory without bound.
    private static let maxTableEntries = 2_000_000
    /// Deepest ply with killer slots.
    private static let maxKillerPly = 128
    /// Null-move depth reduction (R = 2, applied on top of the normal -1).
    private static let nullMoveReduction = 2

    enum Bound {
        case exact, lower, upper
    }

    struct TTEntry {
        let depth: Int
        /// Mate scores are stored relative to the entry's node (see
        /// `storeScore`/`probeScore`) so they stay correct at any ply.
        let score: Int
        let bound: Bound
        let move: Move?
        /// The search-call counter in effect when this entry was stored.
        /// Only ``PersistentNegamaxEngine`` sets and reads it — to evict the
        /// oldest entries first when its table is capped. The deterministic
        /// struct leaves it at 0 and never evicts, so it can't affect probes
        /// or node counts.
        var generation: UInt32 = 0
    }

    /// Readable after the search so a persistent engine can keep it warm.
    private(set) var table: [UInt64: TTEntry]
    /// Two killer (quiet refutation) moves per ply.
    private var killers = [(Move?, Move?)](repeating: (nil, nil), count: maxKillerPly)
    /// Quiet-move history scores indexed by from*64+to, bumped on cutoffs.
    private var history = [Int](repeating: 0, count: 64 * 64)

    private let maxNodes: Int?
    private let deadline: ContinuousClock.Instant?
    /// Optional external interrupt (e.g. "the opponent moved, stop pondering").
    private let stop: SearchStopSignal?
    /// Stamped onto every entry this session stores, so a persistent engine
    /// can evict by age. Left at 0 for the deterministic struct.
    private let generation: UInt32

    init(
        limit: SearchLimit,
        table: [UInt64: TTEntry] = [:],
        stop: SearchStopSignal? = nil,
        generation: UInt32 = 0
    ) {
        self.table = table
        self.stop = stop
        self.generation = generation
        self.maxNodes = limit.maxNodes
        self.deadline = limit.moveTime.map { ContinuousClock.now + .seconds($0) }
    }

    /// Checks limits (time and the stop signal only every 1024 nodes — clock
    /// reads and lock acquisitions aren't free).
    private func checkAbort() -> Bool {
        if aborted { return true }
        guard abortAllowed else { return false }
        if let maxNodes, nodes >= maxNodes {
            aborted = true
        } else if nodes & 1023 == 0 {
            if let stop, stop.isStopRequested {
                aborted = true
            } else if let deadline, ContinuousClock.now >= deadline {
                aborted = true
            }
        }
        return aborted
    }

    private func staticEval(_ b: Board) -> Int {
        // Terminal positions are handled before stand-pat, so the cheap
        // movegen-free evaluation is safe here — and it's the difference
        // between a usable and an unusable search speed.
        b.sideToMove == .white ? b.evaluateFast() : -b.evaluateFast()
    }

    private func isQuiet(_ move: Move, in board: Board) -> Bool {
        board[move.to] == nil
            && move.promotion == nil
            && !(board[move.from]?.kind == .pawn && move.to == board.enPassantSquare)
    }

    /// Move ordering: `first` (TT/previous-iteration best), then promotions
    /// and captures by MVV-LVA, then killer moves for this ply, then quiet
    /// moves by history score.
    func ordered(_ moves: [Move], in board: Board, first: Move?, ply: Int) -> [Move] {
        let killerPair = killers[min(ply, Self.maxKillerPly - 1)]
        func priority(_ move: Move) -> Int {
            if move == first { return .max }
            var score = 0
            if let promotion = move.promotion {
                score += 10_000 + promotion.centipawnValue
            }
            if let victim = board[move.to] {
                let attacker = board[move.from]?.kind.centipawnValue ?? 0
                score += 1_100 + victim.kind.centipawnValue * 10 - attacker
            } else if board[move.from]?.kind == .pawn, move.to == board.enPassantSquare {
                score += 1_100 + PieceKind.pawn.centipawnValue * 10 - PieceKind.pawn.centipawnValue
            } else {
                // Quiets: killers first, then history heat.
                if move == killerPair.0 { return 1_050 }
                if move == killerPair.1 { return 1_040 }
                score = min(1_000, history[move.from * 64 + move.to])
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

    private func recordCutoff(_ move: Move, in board: Board, depth: Int, ply: Int) {
        guard isQuiet(move, in: board) else { return }
        let slot = min(ply, Self.maxKillerPly - 1)
        if killers[slot].0 != move {
            killers[slot].1 = killers[slot].0
            killers[slot].0 = move
        }
        history[move.from * 64 + move.to] += depth * depth
        // Keep history scores discriminating: halve everything when hot.
        if history[move.from * 64 + move.to] > 100_000 {
            for i in history.indices { history[i] /= 2 }
        }
    }

    /// True if `side` has any piece besides king and pawns (null-move guard:
    /// zugzwang is overwhelmingly a king-and-pawn phenomenon).
    private func hasNonPawnMaterial(_ b: Board, side: PieceColor) -> Bool {
        for square in 0..<64 {
            if let piece = b[square], piece.color == side,
               piece.kind != .pawn, piece.kind != .king {
                return true
            }
        }
        return false
    }

    /// Negamax with alpha-beta, transposition table, and null-move pruning.
    /// Returns a score from the perspective of `b`'s side to move. `ply` is
    /// the distance from the root. Meaningless once `aborted` is set —
    /// callers must check.
    func negamax(
        _ b: Board, depth: Int, alpha: Int, beta: Int, ply: Int,
        extensions: Int = 0, allowNull: Bool = true
    ) -> Int {
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
        let inCheck = b.isInCheck(b.sideToMove)
        if inCheck, extensions < Self.maxExtensions {
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

        // Null-move pruning: if passing the move still busts beta, an actual
        // move surely will. Skipped in check, near the horizon, when material
        // is pawns-only (zugzwang), and never twice in a row.
        if allowNull, !inCheck, depth >= 3,
           beta < NegamaxEngine.mateThreshold,
           hasNonPawnMaterial(b, side: b.sideToMove) {
            let reduced = max(0, depth - 1 - Self.nullMoveReduction)
            let nullScore = -negamax(
                b.makingNullMove(), depth: reduced,
                alpha: -beta, beta: -beta + 1,
                ply: ply + 1, extensions: extensions, allowNull: false
            )
            if aborted { return 0 }
            if nullScore >= beta, nullScore < NegamaxEngine.mateThreshold {
                return nullScore
            }
        }

        var best = Int.min + 1
        var bestMove: Move?
        var a = alpha
        for move in ordered(moves, in: b, first: ttMove, ply: ply) {
            guard let next = b.making(move) else { continue }
            let score = -negamax(
                next, depth: depth - 1, alpha: -beta, beta: -a,
                ply: ply + 1, extensions: extensions
            )
            if aborted { return 0 }
            if score > best {
                best = score
                bestMove = move
            }
            if score > a { a = score }
            if a >= beta {
                recordCutoff(move, in: b, depth: depth, ply: ply)
                break
            }
        }

        if table.count < Self.maxTableEntries {
            let bound: Bound = best >= beta ? .lower : (best <= alpha ? .upper : .exact)
            table[key] = TTEntry(
                depth: depth,
                score: Self.storeScore(best, ply: ply),
                bound: bound,
                move: bestMove,
                generation: generation
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
            candidates = moves.filter { !isQuiet($0, in: b) }
        }

        for move in ordered(candidates, in: b, first: nil, ply: ply) {
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
