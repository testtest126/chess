import ChessKit

/// A named position in the bench suite.
public struct BenchPosition: Sendable {
    public let name: String
    public let fen: String

    public init(name: String, fen: String) {
        self.name = name
        self.fen = fen
    }
}

/// Parses a FEN known to be valid (the built-in suites are hardcoded). Traps on
/// a malformed constant rather than force-unwrapping, which keeps the production
/// target free of `!` and turns a typo into a clear message.
func parseFEN(_ fen: String) -> Board {
    guard let board = Board(fen: fen) else {
        preconditionFailure("EngineLab: invalid FEN in built-in suite: \(fen)")
    }
    return board
}

/// The fixed bench suite: 20 positions spanning openings, tactical middlegames,
/// and endgames, chosen for a mix of branching factors so the total node count
/// is a broad, stable fingerprint of search behavior. Order is fixed — the
/// bench signature folds in each position's index, so reordering changes it.
public enum BenchSuite {
    public static let positions: [BenchPosition] = [
        // Openings / early middlegame
        .init(name: "startpos", fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"),
        .init(name: "italian", fen: "r1bqk1nr/pppp1ppp/2n5/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4"),
        .init(name: "ruy-lopez", fen: "r1bqkbnr/1ppp1ppp/p1n5/1B2p3/4P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 0 4"),
        .init(name: "najdorf", fen: "rnbqkb1r/1p2pppp/p2p1n2/8/3NP3/2N5/PPP2PPP/R1BQKB1R w KQkq - 0 6"),
        .init(name: "qgd", fen: "rnbqkb1r/ppp1pppp/5n2/3p4/2PP4/8/PP2PPPP/RNBQKBNR w KQkq - 0 3"),
        .init(name: "french", fen: "rnbqkb1r/ppp2ppp/4pn2/3p4/2PP4/2N5/PP2PPPP/R1BQKBNR w KQkq - 0 4"),
        // Rich middlegames (high branching factor)
        .init(name: "kid-middlegame", fen: "r1bq1rk1/pp2bppp/2n1pn2/3p4/2PP4/2N1PN2/PP2BPPP/R1BQ1RK1 w - - 0 8"),
        .init(name: "kiwipete", fen: "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"),
        .init(name: "perft-pos4", fen: "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1"),
        .init(name: "perft-pos5", fen: "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8"),
        .init(name: "perft-pos6", fen: "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10"),
        // Tactical (Win At Chess) test positions
        .init(name: "wac-001", fen: "2rr3k/pp3pp1/1nnqbN1p/3pN3/2pP4/2P3Q1/PPB4P/R4RK1 w - - 0 1"),
        .init(name: "wac-002", fen: "8/7p/5k2/5p2/p1p2P2/Pr1pPK2/1P1R3P/8 b - - 0 1"),
        .init(name: "wac-010", fen: "3r1r1k/1p3pp1/p2q1n1p/8/2p1B3/P1P3Q1/1P3PPP/2K1R2R w - - 0 1"),
        // Endgames (low branching, deep tactics)
        .init(name: "rook-mate", fen: "6k1/5ppp/8/8/8/8/8/R3K3 w - - 0 1"),
        .init(name: "kq-vs-k", fen: "8/8/8/4k3/8/8/8/3QK3 w - - 0 1"),
        .init(name: "kr-vs-k", fen: "8/8/8/4k3/8/8/8/R3K3 w - - 0 1"),
        .init(name: "pawn-endgame", fen: "8/5p2/5k2/8/5K2/8/5P2/8 w - - 0 1"),
        .init(name: "rook-endgame", fen: "8/8/5k2/8/8/2K5/4R3/6r1 w - - 0 1"),
        .init(name: "opposite-bishops", fen: "8/2k5/3b4/8/8/4B3/2K5/8 w - - 0 1"),
    ]
}
