import Foundation
import ChessKit

/// An opening book: positions mapped to known-good moves, each with a
/// popularity weight. Built from mainline move sequences and keyed by
/// `Board.repetitionKey`, so transposing into a book position still hits the
/// book. Weights let ``randomMove(for:seed:)`` prefer well-established moves
/// over rare sidelines instead of picking uniformly at random.
public struct OpeningBook: Sendable {
    public struct WeightedMove: Equatable, Sendable {
        public let move: Move
        public let weight: Int
    }

    private let entries: [String: [WeightedMove]]

    /// Builds a book from lines of space-separated UCI moves, each starting
    /// from the initial position. A move seen more than once at the same
    /// position (e.g. across two lines, or twice in one) accumulates weight
    /// rather than being ignored. Illegal moves end their line (asserting in
    /// debug builds) so a typo can't poison the book.
    public init(lines: [String]) {
        var entries: [String: [WeightedMove]] = [:]
        for line in lines {
            var game = Game()
            for uci in line.split(separator: " ").map(String.init) {
                guard let move = Move(uci: uci), game.board.isLegal(move) else {
                    assertionFailure("illegal book move \(uci) in line: \(line)")
                    break
                }
                Self.bump(move, at: game.board.repetitionKey, in: &entries)
                guard (try? game.play(move)) != nil else { break }
            }
        }
        self.entries = entries
    }

    /// Builds a book from precomputed compact rows, one per line:
    /// `"<space-separated UCI prefix>|<UCI move>|<weight>"`, where prefix is
    /// empty for a move played from the initial position. Each row replays
    /// only its own (typically short) prefix once, so this stays fast even
    /// for thousands of rows — unlike ``init(lines:)``, it doesn't need every
    /// row to be a full game transcript. Malformed or illegal rows are
    /// skipped rather than asserting, since this path is meant for large,
    /// externally-generated data (see `tools/opening-book/`) that hasn't been
    /// hand-reviewed line by line.
    public init(compactRows: [String]) {
        var entries: [String: [WeightedMove]] = [:]
        for row in compactRows {
            let parts = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, let weight = Int(parts[2]), weight > 0,
                  let move = Move(uci: parts[1]) else { continue }

            var game = Game()
            var prefixOK = true
            if !parts[0].isEmpty {
                for uci in parts[0].split(separator: " ").map(String.init) {
                    guard let prefixMove = Move(uci: uci), game.board.isLegal(prefixMove),
                          (try? game.play(prefixMove)) != nil else {
                        prefixOK = false
                        break
                    }
                }
            }
            guard prefixOK, game.board.isLegal(move) else { continue }
            Self.bump(move, weight: weight, at: game.board.repetitionKey, in: &entries)
        }
        self.entries = entries
    }

    private static func bump(
        _ move: Move, weight: Int = 1, at key: String, in entries: inout [String: [WeightedMove]]
    ) {
        if let index = entries[key, default: []].firstIndex(where: { $0.move == move }) {
            entries[key]![index] = WeightedMove(move: move, weight: entries[key]![index].weight + weight)
        } else {
            entries[key, default: []].append(WeightedMove(move: move, weight: weight))
        }
    }

    /// Book moves for this position (empty when out of book), most-seen
    /// first is not guaranteed — use ``weightedMoves(for:)`` for weights.
    public func moves(for board: Board) -> [Move] {
        (entries[board.repetitionKey] ?? []).map(\.move)
    }

    /// Book moves with their popularity weights (empty when out of book).
    public func weightedMoves(for board: Board) -> [WeightedMove] {
        entries[board.repetitionKey] ?? []
    }

    /// Picks a book move for this position, weighted by popularity, or `nil`
    /// when out of book. Deterministic: the same book, position, and seed
    /// always produce the same move, so a caller that wants reproducible
    /// play (tests, replaying a game) can fix the seed, while one that wants
    /// natural game-to-game variety can pass a fresh random seed per game.
    public func randomMove(for board: Board, seed: UInt64) -> Move? {
        let candidates = weightedMoves(for: board)
        guard !candidates.isEmpty else { return nil }
        let totalWeight = candidates.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return candidates[0].move }

        var rng = SplitMix64(seed: seed ^ Self.stableHash(board.repetitionKey))
        let pick = Int(rng.next() % UInt64(totalWeight))
        var cumulative = 0
        for candidate in candidates {
            cumulative += candidate.weight
            if pick < cumulative { return candidate.move }
        }
        return candidates.last?.move
    }

    /// FNV-1a over UTF-8 bytes. Deterministic across runs and processes,
    /// unlike `String.hashValue` (randomized per-process for DoS hardening),
    /// which book seeding needs in order to be reproducible.
    private static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    public var positionCount: Int { entries.count }

    /// Mainlines of common openings, roughly the first four to six moves.
    public static let standard = OpeningBook(lines: [
        // Ruy Lopez
        "e2e4 e7e5 g1f3 b8c6 f1b5 a7a6 b5a4 g8f6 e1g1 f8e7 f1e1 b7b5 a4b3",
        // Italian Game
        "e2e4 e7e5 g1f3 b8c6 f1c4 f8c5 c2c3 g8f6 d2d3 d7d6 e1g1",
        // Sicilian, Open
        "e2e4 c7c5 g1f3 d7d6 d2d4 c5d4 f3d4 g8f6 b1c3 a7a6",
        // Sicilian, Sveshnikov-ish
        "e2e4 c7c5 g1f3 b8c6 d2d4 c5d4 f3d4 g8f6 b1c3 e7e5",
        // French, Classical
        "e2e4 e7e6 d2d4 d7d5 b1c3 g8f6 c1g5 f8e7 e4e5 f6d7",
        // Caro-Kann, Classical
        "e2e4 c7c6 d2d4 d7d5 b1c3 d5e4 c3e4 c8f5 e4g3 f5g6",
        // Scandinavian
        "e2e4 d7d5 e4d5 d8d5 b1c3 d5a5 d2d4 g8f6 g1f3 c8f5",
        // Queen's Gambit Declined
        "d2d4 d7d5 c2c4 e7e6 b1c3 g8f6 c1g5 f8e7 e2e3 e8g8 g1f3",
        // Slav
        "d2d4 d7d5 c2c4 c7c6 g1f3 g8f6 b1c3 d5c4 a2a4 c8f5",
        // King's Indian Defense
        "d2d4 g8f6 c2c4 g7g6 b1c3 f8g7 e2e4 d7d6 g1f3 e8g8 f1e2 e7e5",
        // Nimzo-Indian
        "d2d4 g8f6 c2c4 e7e6 b1c3 f8b4 e2e3 e8g8 f1d3 d7d5",
        // London System
        "d2d4 g8f6 c1f4 e7e6 e2e3 d7d5 g1f3 f8d6 f4g3 e8g8",
        // English, Reversed Sicilian
        "c2c4 e7e5 b1c3 g8f6 g1f3 b8c6 g2g3 d7d5 c4d5 f6d5 f1g2 d5b6",
        // English, Symmetric
        "c2c4 c7c5 g1f3 g8f6 d2d4 c5d4 f3d4 e7e6 g2g3",
    ])

    /// A larger book built from real game data: the top ~4000 (position,
    /// move) pairs by frequency, up to 10 plies deep, extracted from
    /// testtest126/books' `bjbraams_chessdb_198350_lines.pgn` (198,350 real
    /// database games). See `tools/opening-book/README.md` for provenance
    /// and how to regenerate it. Falls back to an empty book if the bundled
    /// resource is missing so a packaging problem degrades to "no book move,
    /// fall through to search" rather than crashing.
    public static let large: OpeningBook = {
        guard let url = Bundle.module.url(forResource: "opening_book_large", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return OpeningBook(lines: [])
        }
        let rows = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return OpeningBook(compactRows: rows)
    }()
}

/// Minimal splitmix64 PRNG. Used instead of `SystemRandomNumberGenerator` so
/// book move selection can be seeded and reproduced exactly.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
