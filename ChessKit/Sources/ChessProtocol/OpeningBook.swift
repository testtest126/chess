import ChessKit

/// A small opening book: positions mapped to known-good moves. Built from
/// mainline move sequences and keyed by `Board.repetitionKey`, so transposing
/// into a book position still hits the book.
public struct OpeningBook: Sendable {
    private let entries: [String: [Move]]

    /// Builds a book from lines of space-separated UCI moves, each starting
    /// from the initial position. Illegal moves end their line (asserting in
    /// debug builds) so a typo can't poison the book.
    public init(lines: [String]) {
        var entries: [String: [Move]] = [:]
        for line in lines {
            var game = Game()
            for uci in line.split(separator: " ").map(String.init) {
                guard let move = Move(uci: uci), game.board.isLegal(move) else {
                    assertionFailure("illegal book move \(uci) in line: \(line)")
                    break
                }
                let key = game.board.repetitionKey
                if !entries[key, default: []].contains(move) {
                    entries[key, default: []].append(move)
                }
                guard (try? game.play(move)) != nil else { break }
            }
        }
        self.entries = entries
    }

    /// Book moves for this position (empty when out of book).
    public func moves(for board: Board) -> [Move] {
        entries[board.repetitionKey] ?? []
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
}
