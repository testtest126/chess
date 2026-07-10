import Foundation

/// Post-game analysis: per-move evaluations and move quality classification.
///
/// Evaluation is pluggable: the default is the built-in one-ply lookahead
/// (cheap, rough), and callers can supply a real engine-backed evaluator for
/// trustworthy numbers without ChessKit depending on any engine.
public struct GameReview: Sendable {
    /// A position's evaluation: score in centipawns from White's perspective
    /// assuming best play, plus (optionally) the move that achieves it.
    public struct PositionAssessment: Sendable {
        public var score: Int
        public var bestMove: Move?

        public init(score: Int, bestMove: Move? = nil) {
            self.score = score
            self.bestMove = bestMove
        }
    }

    /// Assesses a position. Called once per position in the game.
    public typealias Evaluator = (Board) -> PositionAssessment

    public struct MoveAnalysis: Codable, Sendable, Identifiable {
        public var id: Int { plyIndex }
        /// 0-based ply index into the game's history.
        public let plyIndex: Int
        public let san: String
        public let uci: String
        public let mover: PieceColor
        /// Eval (centipawns, White's perspective) after this move was played.
        public let evalAfter: Int
        /// How many centipawns the mover gave up vs. the best available move. >= 0.
        public let centipawnLoss: Int
        public let judgment: Judgment
        /// SAN of the evaluator's preferred move, when it differs from what
        /// was played. What the review shows as "best was …".
        public let bestSAN: String?
    }

    public enum Judgment: String, Codable, Sendable {
        case best, good, inaccuracy, mistake, blunder

        public init(centipawnLoss loss: Int) {
            switch loss {
            case ..<25: self = .best
            case ..<60: self = .good
            case ..<120: self = .inaccuracy
            case ..<250: self = .mistake
            default: self = .blunder
            }
        }
    }

    public struct Summary: Codable, Sendable {
        public let accuracyWhite: Double
        public let accuracyBlack: Double
        public let blundersWhite: Int
        public let blundersBlack: Int
        public let mistakesWhite: Int
        public let mistakesBlack: Int
        public let inaccuraciesWhite: Int
        public let inaccuraciesBlack: Int
    }

    public let moves: [MoveAnalysis]
    public let summary: Summary
    /// Eval before any move (initial position) followed by eval after each ply.
    /// Length = game.moveCount + 1. White's perspective, centipawns.
    public let evalTimeline: [Int]

    /// Analyzes `game`, evaluating every position exactly once.
    ///
    /// - Parameters:
    ///   - evaluator: White-perspective best-play assessment. Defaults to the
    ///     built-in one-ply lookahead.
    ///   - progress: Called after each position with completed fraction (0-1).
    public init(
        analyzing game: Game,
        evaluator: Evaluator = GameReview.lookaheadEvaluator,
        progress: ((Double) -> Void)? = nil
    ) {
        let positions = game.positions
        var assessments: [PositionAssessment] = []
        assessments.reserveCapacity(positions.count)
        for (i, position) in positions.enumerated() {
            assessments.append(evaluator(position))
            progress?(Double(i + 1) / Double(positions.count))
        }

        var analyses: [MoveAnalysis] = []
        for (i, entry) in game.history.enumerated() {
            let mover = positions[i].sideToMove
            let bestEval = assessments[i].score      // best play from the position before
            let actualEval = assessments[i + 1].score // what the played move led to

            // Loss from the mover's perspective.
            let loss = mover == .white
                ? max(0, bestEval - actualEval)
                : max(0, actualEval - bestEval)
            // Cap: positions already lost/won shouldn't produce absurd loss values.
            let cappedLoss = min(loss, 1000)

            // Only name a better move when one was actually preferred.
            var bestSAN: String?
            if let best = assessments[i].bestMove, best != entry.move {
                bestSAN = positions[i].san(for: best)
            }

            analyses.append(MoveAnalysis(
                plyIndex: i,
                san: entry.san,
                uci: entry.move.uci,
                mover: mover,
                evalAfter: actualEval,
                centipawnLoss: cappedLoss,
                judgment: Judgment(centipawnLoss: cappedLoss),
                bestSAN: bestSAN
            ))
        }

        self.moves = analyses
        self.evalTimeline = assessments.map(\.score)
        self.summary = GameReview.summarize(analyses)
    }

    /// The built-in evaluator: one-ply minimax over the static evaluation,
    /// returning both the value and the move that attains it.
    /// Typed `@Sendable` (it captures nothing) so the shared static is
    /// concurrency-safe in the Swift 6 language mode; it converts to the
    /// plain `Evaluator` function type at every use site.
    public static let lookaheadEvaluator: @Sendable (Board) -> PositionAssessment = { board in
        let moves = board.legalMoves()
        guard !moves.isEmpty else {
            return PositionAssessment(score: board.evaluate())
        }
        var bestScore = board.sideToMove == .white ? Int.min : Int.max
        var bestMove: Move?
        for move in moves {
            var next = board
            next.apply(move)
            let value = next.evaluate()
            if board.sideToMove == .white ? value > bestScore : value < bestScore {
                bestScore = value
                bestMove = move
            }
        }
        return PositionAssessment(score: bestScore, bestMove: bestMove)
    }

    private static func summarize(_ analyses: [MoveAnalysis]) -> Summary {
        func accuracy(for color: PieceColor) -> Double {
            let colorMoves = analyses.filter { $0.mover == color }
            guard !colorMoves.isEmpty else { return 100 }
            // Lichess-style: map average centipawn loss to a 0-100 score.
            let acl = Double(colorMoves.map(\.centipawnLoss).reduce(0, +)) / Double(colorMoves.count)
            let score = 103.16 * exp(-0.04354 * acl) - 3.17
            return min(100, max(0, score))
        }
        func count(_ judgment: Judgment, _ color: PieceColor) -> Int {
            analyses.filter { $0.mover == color && $0.judgment == judgment }.count
        }
        return Summary(
            accuracyWhite: accuracy(for: .white),
            accuracyBlack: accuracy(for: .black),
            blundersWhite: count(.blunder, .white),
            blundersBlack: count(.blunder, .black),
            mistakesWhite: count(.mistake, .white),
            mistakesBlack: count(.mistake, .black),
            inaccuraciesWhite: count(.inaccuracy, .white),
            inaccuraciesBlack: count(.inaccuracy, .black)
        )
    }
}
