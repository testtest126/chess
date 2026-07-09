import Foundation

/// Post-game analysis: per-move evaluations and move quality classification.
/// Uses the built-in heuristic evaluator with shallow lookahead — designed to be
/// swapped for a real engine (Stockfish) later without changing the data model.
public struct GameReview: Sendable {
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

    public init(analyzing game: Game) {
        var analyses: [MoveAnalysis] = []
        var timeline: [Int] = []

        let positions = game.positions
        timeline.append(positions[0].evaluate())

        for (i, entry) in game.history.enumerated() {
            let before = positions[i]
            let after = entry.board
            let mover = before.sideToMove

            // Best achievable eval from `before` (one-ply minimax).
            let bestEval = before.evaluateWithLookahead()
            let actualEval = after.evaluate()
            timeline.append(actualEval)

            // Loss from the mover's perspective.
            let loss: Int
            if mover == .white {
                loss = max(0, bestEval - actualEval)
            } else {
                loss = max(0, actualEval - bestEval)
            }
            // Cap: positions already lost/won shouldn't produce absurd loss values.
            let cappedLoss = min(loss, 1000)

            analyses.append(MoveAnalysis(
                plyIndex: i,
                san: entry.san,
                uci: entry.move.uci,
                mover: mover,
                evalAfter: actualEval,
                centipawnLoss: cappedLoss,
                judgment: Judgment(centipawnLoss: cappedLoss)
            ))
        }

        self.moves = analyses
        self.evalTimeline = timeline
        self.summary = GameReview.summarize(analyses)
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
