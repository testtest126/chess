import ChessKit
import ChessProtocol

/// A named opening position for self-play. Games start here rather than from
/// the initial position so a deterministic engine produces a spread of games
/// instead of replaying one line.
public struct Opening: Sendable {
    public let name: String
    public let fen: String

    public init(name: String, fen: String) {
        self.name = name
        self.fen = fen
    }
}

/// A small, balanced opening set. Each opening is played twice in a match (once
/// with each engine as White), so a match is `2 * openings.count` games.
public enum Openings {
    public static let standard: [Opening] = [
        .init(name: "open-game", fen: "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"),
        .init(name: "sicilian", fen: "rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"),
        .init(name: "french", fen: "rnbqkbnr/pppp1ppp/4p3/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"),
        .init(name: "caro-kann", fen: "rnbqkbnr/pp1ppppp/2p5/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"),
        .init(name: "scandinavian", fen: "rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"),
        .init(name: "closed-d4", fen: "rnbqkbnr/ppp1pppp/8/3p4/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 0 2"),
        .init(name: "indian", fen: "rnbqkb1r/pppppppp/5n2/8/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 1 2"),
        .init(name: "qgd", fen: "rnbqkb1r/pppp1ppp/4pn2/8/2PP4/8/PP2PPPP/RNBQKBNR w KQkq - 0 3"),
        .init(name: "kings-indian", fen: "rnbqkb1r/pppppp1p/5np1/8/2PP4/8/PP2PPPP/RNBQKBNR w KQkq - 0 3"),
        .init(name: "english", fen: "rnbqkbnr/pppppppp/8/8/2P5/8/PP1PPPPP/RNBQKBNR b KQkq - 0 1"),
        .init(name: "reti", fen: "rnbqkbnr/ppp1pppp/8/3p4/8/5N2/PPPPPPPP/RNBQKB1R w KQkq - 0 2"),
        .init(name: "pirc", fen: "rnbqkb1r/ppp1pppp/3p1n2/8/3PP3/8/PPP2PPP/RNBQKBNR w KQkq - 0 3"),
    ]
}

/// One engine participant in a match: a label plus the search limit (and
/// optional book) it plays under. Two configs differing only in `limit` (depth
/// or node budget) let a match measure how much a given amount of extra search
/// is worth in Elo. Leave `book` nil to keep games reproducible.
public struct EngineConfig: Sendable {
    public let label: String
    public let limit: SearchLimit
    public let book: OpeningBook?

    public init(label: String, limit: SearchLimit, book: OpeningBook? = nil) {
        self.label = label
        self.limit = limit
        self.book = book
    }

    func makeEngine() -> NegamaxEngine {
        NegamaxEngine(book: book)
    }
}

public enum GameResult: Sendable {
    case whiteWin
    case blackWin
    case draw
}

public enum GameEndReason: String, Sendable {
    case checkmate
    case stalemate
    case fiftyMove
    case insufficientMaterial
    case threefold
    case plyCap
}

public struct GameOutcome: Sendable {
    public let result: GameResult
    public let reason: GameEndReason
    public let plies: Int
}

/// Match result from engine A's perspective (`wins`/`losses` are A's).
public struct MatchResult: Sendable {
    public let aLabel: String
    public let bLabel: String
    public let wins: Int
    public let draws: Int
    public let losses: Int

    public var games: Int { wins + draws + losses }

    /// A's score fraction: (wins + ½·draws) / games.
    public var scoreA: Double {
        guard games > 0 else { return 0 }
        return (Double(wins) + 0.5 * Double(draws)) / Double(games)
    }

    /// Elo of A relative to B (positive ⇒ A is stronger over these games).
    public var eloDelta: Double { Elo.difference(forScore: scoreA) }

    /// 95% confidence half-width around `eloDelta`.
    public var eloMargin: Double { Elo.errorMargin95(wins: wins, draws: draws, losses: losses) }
}

/// Deterministic engine-vs-engine play. Every game is fully determined by the
/// two configs, the start position, and the ply cap — no clocks, no randomness
/// (as long as neither config carries a book), so a match is reproducible.
public enum SelfPlay {
    /// Absolute cap on game length; a game hitting it is scored as a draw. Well
    /// above the 50-move rule, so it only fires on genuine non-progress the
    /// draw rules somehow miss.
    public static let defaultMaxPlies = 400

    /// Plays a single game. `white`/`black` are the configs by color.
    public static func playGame(
        white: EngineConfig,
        black: EngineConfig,
        from start: Board,
        maxPlies: Int = defaultMaxPlies
    ) -> GameOutcome {
        let whiteEngine = white.makeEngine()
        let blackEngine = black.makeEngine()
        var board = start

        // Track positions for threefold repetition. The invariant across the
        // loop is that the current board's key has already been counted.
        var seen: [String: Int] = [:]
        seen[board.repetitionKey, default: 0] += 1

        for ply in 0..<maxPlies {
            switch board.status {
            case .checkmate(let winner):
                return GameOutcome(
                    result: winner == .white ? .whiteWin : .blackWin,
                    reason: .checkmate, plies: ply
                )
            case .stalemate:
                return GameOutcome(result: .draw, reason: .stalemate, plies: ply)
            case .fiftyMoveDraw:
                return GameOutcome(result: .draw, reason: .fiftyMove, plies: ply)
            case .insufficientMaterial:
                return GameOutcome(result: .draw, reason: .insufficientMaterial, plies: ply)
            case .ongoing:
                break
            }
            if seen[board.repetitionKey, default: 0] >= 3 {
                return GameOutcome(result: .draw, reason: .threefold, plies: ply)
            }

            let config = board.sideToMove == .white ? white : black
            let engine = board.sideToMove == .white ? whiteEngine : blackEngine
            let search = engine.search(board, limit: config.limit)
            guard let move = search.bestMove, let next = board.making(move) else {
                // `status` was `.ongoing`, so a legal move exists; reaching here
                // would mean the engine returned nothing. Adjudicate a draw
                // rather than trap — the harness must always finish a game.
                return GameOutcome(result: .draw, reason: .stalemate, plies: ply)
            }
            board = next
            seen[board.repetitionKey, default: 0] += 1
        }
        return GameOutcome(result: .draw, reason: .plyCap, plies: maxPlies)
    }

    /// Plays a full match: every opening twice, colors swapped, so color bias
    /// cancels. Returns results from A's perspective.
    public static func playMatch(
        a: EngineConfig,
        b: EngineConfig,
        openings: [Opening] = Openings.standard,
        maxPlies: Int = defaultMaxPlies
    ) -> MatchResult {
        var wins = 0
        var draws = 0
        var losses = 0

        func tally(_ outcome: GameOutcome, aIsWhite: Bool) {
            switch outcome.result {
            case .draw:
                draws += 1
            case .whiteWin:
                if aIsWhite { wins += 1 } else { losses += 1 }
            case .blackWin:
                if aIsWhite { losses += 1 } else { wins += 1 }
            }
        }

        for opening in openings {
            let start = parseFEN(opening.fen)
            tally(playGame(white: a, black: b, from: start, maxPlies: maxPlies), aIsWhite: true)
            tally(playGame(white: b, black: a, from: start, maxPlies: maxPlies), aIsWhite: false)
        }

        return MatchResult(aLabel: a.label, bLabel: b.label, wins: wins, draws: draws, losses: losses)
    }
}
