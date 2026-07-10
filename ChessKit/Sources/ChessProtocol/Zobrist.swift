import ChessKit

/// Zobrist position hashing: a 64-bit key over piece placement, castling
/// rights, en passant file, and side to move. Keys are computed from scratch
/// per position (ChessKit boards don't carry incremental hashes); that's an
/// O(64) walk, which is cheap next to move generation.
enum Zobrist {
    /// Deterministic 64-bit generator (SplitMix64) so tables — and therefore
    /// node counts — are identical on every run.
    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// 12 piece kinds × 64 squares.
    private static let pieces: [UInt64] = generate(count: 12 * 64, seed: 0xC4E55)
    /// One entry per castling-rights bitmask value.
    private static let castling: [UInt64] = generate(count: 16, seed: 0xCA57)
    /// One entry per en passant file.
    private static let enPassantFile: [UInt64] = generate(count: 8, seed: 0xE9)
    private static let blackToMove: UInt64 = generate(count: 1, seed: 0x51DE)[0]

    private static func generate(count: Int, seed: UInt64) -> [UInt64] {
        var rng = SplitMix64(state: seed)
        return (0..<count).map { _ in rng.next() }
    }

    private static func pieceIndex(_ piece: Piece) -> Int {
        let kind: Int
        switch piece.kind {
        case .pawn: kind = 0
        case .knight: kind = 1
        case .bishop: kind = 2
        case .rook: kind = 3
        case .queen: kind = 4
        case .king: kind = 5
        }
        return (piece.color == .white ? 0 : 6) + kind
    }

    static func key(for board: Board) -> UInt64 {
        var key: UInt64 = 0
        for square in 0..<64 {
            if let piece = board[square] {
                key ^= pieces[pieceIndex(piece) * 64 + square]
            }
        }
        key ^= castling[board.castlingRights.rawValue & 15]
        if let ep = board.enPassantSquare {
            key ^= enPassantFile[Sq.file(ep)]
        }
        if board.sideToMove == .black {
            key ^= blackToMove
        }
        return key
    }
}
