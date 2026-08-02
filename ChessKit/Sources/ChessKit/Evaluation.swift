import Foundation

// MARK: - Static evaluation

extension Board {
    /// Static evaluation in centipawns from White's perspective. Includes
    /// terminal-state detection (a full legal-move generation via `status`),
    /// so it's comparatively expensive — search hot paths that already know
    /// the position isn't terminal should use ``evaluateFast()``.
    public func evaluate() -> Int {
        switch status {
        case .checkmate(let winner): return winner == .white ? 100_000 : -100_000
        case .stalemate, .fiftyMoveDraw, .insufficientMaterial: return 0
        case .ongoing: return evaluateFast()
        }
    }

    /// Material + tapered piece-square tables + mobility + pawn structure +
    /// king safety + bishop pair, with no move generation at all. Callers are
    /// responsible for handling terminal positions (checkmate/stalemate/draws)
    /// themselves. This is the engine's search hot path (called on every
    /// quiescence leaf), so every term here is a direct array/offset
    /// computation — no `Move` construction, no legality filtering.
    public func evaluateFast() -> Int {
        Eval.score(self)
    }
}

/// A classical "modern-classical" evaluation: material, tapered piece-square
/// tables (a separate endgame king table so the king runs to the center once
/// material thins out), pseudo-mobility, pawn structure (doubled/isolated/
/// passed), a king-safety pawn shield, and the bishop-pair bonus.
///
/// Middlegame and endgame terms are accumulated separately and blended by
/// `phase` (Fruit-style tapering), so evaluation shifts smoothly across the
/// game instead of jumping at a hard phase boundary.
public enum Eval {
    /// TEMPORARY measurement toggle — not part of the shipped engine. Set to
    /// `true` to fall back to flat material + single-table PST (the pre-change
    /// evaluation), for an A/B self-play comparison. Revert before merging.
    nonisolated(unsafe) public static var legacyMaterialAndPSTOnly = false

    /// Phase weight per piece kind, summed over the whole board. Full
    /// material (4N + 4B + 4R*2 + 2Q*4) = 24; an empty-ish endgame is near 0.
    private static func phaseWeight(_ kind: PieceKind) -> Int {
        switch kind {
        case .knight, .bishop: return 1
        case .rook: return 2
        case .queen: return 4
        case .pawn, .king: return 0
        }
    }
    private static let maxPhase = 24

    /// Centipawn bonus per pseudo-legal destination square (knights/bishops/
    /// rooks/queens only — pawns and kings aren't worth the extra scan cost).
    private static let mobilityWeight = 2

    static func score(_ b: Board) -> Int {
        if legacyMaterialAndPSTOnly {
            var score = 0
            for i in 0..<64 {
                guard let piece = b[i] else { continue }
                let value = piece.kind.centipawnValue + PST.bonus(for: piece, at: i)
                score += piece.color == .white ? value : -value
            }
            return score
        }

        var mg = 0
        var eg = 0
        var phase = 0
        var mobility = 0
        var whiteBishops = 0
        var blackBishops = 0
        var whiteKing = -1
        var blackKing = -1
        var whitePawns: [Int] = []
        var blackPawns: [Int] = []

        for i in 0..<64 {
            guard let piece = b[i] else { continue }
            let sign = piece.color == .white ? 1 : -1
            phase += phaseWeight(piece.kind)

            if piece.kind == .king {
                if piece.color == .white { whiteKing = i } else { blackKing = i }
                mg += sign * PST.kingBonus(at: i, color: piece.color, table: PST.kingMiddlegame)
                eg += sign * PST.kingBonus(at: i, color: piece.color, table: PST.kingEndgame)
                continue
            }

            let value = piece.kind.centipawnValue + PST.bonus(for: piece, at: i)
            mg += sign * value
            eg += sign * value

            switch piece.kind {
            case .pawn:
                if piece.color == .white { whitePawns.append(i) } else { blackPawns.append(i) }
            case .bishop:
                if piece.color == .white { whiteBishops += 1 } else { blackBishops += 1 }
                mobility += sign * mobilityCount(b, at: i, kind: .bishop, color: piece.color)
            case .knight, .rook, .queen:
                mobility += sign * mobilityCount(b, at: i, kind: piece.kind, color: piece.color)
            default: break
            }
        }

        // Bishop pair: two bishops cover both color complexes, worth more as
        // the board opens up towards the endgame.
        if whiteBishops >= 2 { mg += 30; eg += 45 }
        if blackBishops >= 2 { mg -= 30; eg -= 45 }

        mg += mobility * mobilityWeight
        eg += mobility * mobilityWeight

        let whiteStructure = pawnStructure(whitePawns, enemyPawns: blackPawns, color: .white)
        let blackStructure = pawnStructure(blackPawns, enemyPawns: whitePawns, color: .black)
        mg += whiteStructure.mg - blackStructure.mg
        eg += whiteStructure.eg - blackStructure.eg

        // King safety is a middlegame concern only: adding it exclusively to
        // `mg` makes it fade out on its own as the taper shifts toward `eg`.
        mg += kingShieldPenalty(b, kingSquare: whiteKing, color: .white)
        mg -= kingShieldPenalty(b, kingSquare: blackKing, color: .black)

        let mgWeight = min(phase, maxPhase)
        let egWeight = maxPhase - mgWeight
        return (mg * mgWeight + eg * egWeight) / maxPhase
    }

    /// Pseudo-mobility: destination squares reachable ignoring pins and whose
    /// own side to move it is (a cheap proxy for real mobility, not exact —
    /// exact mobility needs full legal move generation, too slow for a
    /// per-node search term).
    private static func mobilityCount(_ b: Board, at square: Int, kind: PieceKind, color: PieceColor) -> Int {
        let f = Sq.file(square), r = Sq.rank(square)
        var count = 0

        if kind == .knight {
            for (df, dr) in Board.knightOffsets {
                let nf = f + df, nr = r + dr
                guard Sq.isValid(file: nf, rank: nr) else { continue }
                if b[Sq.index(file: nf, rank: nr)]?.color != color { count += 1 }
            }
            return count
        }

        let dirs: [(Int, Int)]
        switch kind {
        case .bishop: dirs = Board.bishopDirs
        case .rook: dirs = Board.rookDirs
        default: dirs = Board.bishopDirs + Board.rookDirs
        }
        for (df, dr) in dirs {
            var nf = f + df, nr = r + dr
            while Sq.isValid(file: nf, rank: nr) {
                let sq = Sq.index(file: nf, rank: nr)
                if let occupant = b[sq] {
                    if occupant.color != color { count += 1 }
                    break
                }
                count += 1
                nf += df; nr += dr
            }
        }
        return count
    }

    /// Doubled/isolated/passed pawn terms for one side, in (middlegame,
    /// endgame) centipawns. Passed pawns are weighted more heavily toward the
    /// endgame, where an unopposed runner matters most.
    private static func pawnStructure(_ pawns: [Int], enemyPawns: [Int], color: PieceColor) -> (mg: Int, eg: Int) {
        guard !pawns.isEmpty else { return (0, 0) }
        var fileCounts = [Int](repeating: 0, count: 8)
        for sq in pawns { fileCounts[Sq.file(sq)] += 1 }

        var mg = 0
        var eg = 0
        for sq in pawns {
            let f = Sq.file(sq), r = Sq.rank(sq)

            if fileCounts[f] > 1 {
                mg -= 10; eg -= 20
            }

            let hasNeighborFile = (f > 0 && fileCounts[f - 1] > 0) || (f < 7 && fileCounts[f + 1] > 0)
            if !hasNeighborFile {
                mg -= 12; eg -= 18
            }

            let isPassed = !enemyPawns.contains { enemy in
                let ef = Sq.file(enemy), er = Sq.rank(enemy)
                guard abs(ef - f) <= 1 else { return false }
                return color == .white ? er > r : er < r
            }
            if isPassed {
                // Ranks advanced from the second rank (0 = still on it, 6 = one step from promoting).
                let advanced = color == .white ? r - 1 : 6 - r
                let bonus = passedPawnBonus[max(0, min(advanced, passedPawnBonus.count - 1))]
                mg += bonus / 2
                eg += bonus
            }
        }
        return (mg, eg)
    }

    private static let passedPawnBonus = [0, 5, 10, 20, 35, 60, 100]

    /// Penalty (always <= 0) for missing pawn-shield squares directly in
    /// front of the king. Ignored once the king has no adjacent files on the
    /// board edge cases aside, this is a coarse but cheap safety proxy.
    private static func kingShieldPenalty(_ b: Board, kingSquare: Int, color: PieceColor) -> Int {
        guard kingSquare >= 0 else { return 0 }
        let f = Sq.file(kingSquare), r = Sq.rank(kingSquare)
        let forwardRank = r + (color == .white ? 1 : -1)
        guard Sq.isValid(file: f, rank: forwardRank) else { return 0 }

        var slots = 0
        var shieldPawns = 0
        for df in -1...1 {
            let sf = f + df
            guard Sq.isValid(file: sf, rank: forwardRank) else { continue }
            slots += 1
            if b[Sq.index(file: sf, rank: forwardRank)] == Piece(color: color, kind: .pawn) {
                shieldPawns += 1
            }
        }
        guard slots > 0 else { return 0 }
        return (shieldPawns - slots) * 8
    }
}

// MARK: - Piece-square tables

enum PST {
    // Tables are from White's perspective, index by square (a1 = 0).
    static let pawn: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0,
        5, 10, 10, -20, -20, 10, 10, 5,
        5, -5, -10, 0, 0, -10, -5, 5,
        0, 0, 0, 20, 20, 0, 0, 0,
        5, 5, 10, 25, 25, 10, 5, 5,
        10, 10, 20, 30, 30, 20, 10, 10,
        50, 50, 50, 50, 50, 50, 50, 50,
        0, 0, 0, 0, 0, 0, 0, 0,
    ]
    static let knight: [Int] = [
        -50, -40, -30, -30, -30, -30, -40, -50,
        -40, -20, 0, 5, 5, 0, -20, -40,
        -30, 5, 10, 15, 15, 10, 5, -30,
        -30, 0, 15, 20, 20, 15, 0, -30,
        -30, 5, 15, 20, 20, 15, 5, -30,
        -30, 0, 10, 15, 15, 10, 0, -30,
        -40, -20, 0, 0, 0, 0, -20, -40,
        -50, -40, -30, -30, -30, -30, -40, -50,
    ]
    static let bishop: [Int] = [
        -20, -10, -10, -10, -10, -10, -10, -20,
        -10, 5, 0, 0, 0, 0, 5, -10,
        -10, 10, 10, 10, 10, 10, 10, -10,
        -10, 0, 10, 10, 10, 10, 0, -10,
        -10, 5, 5, 10, 10, 5, 5, -10,
        -10, 0, 5, 10, 10, 5, 0, -10,
        -10, 0, 0, 0, 0, 0, 0, -10,
        -20, -10, -10, -10, -10, -10, -10, -20,
    ]
    static let rook: [Int] = [
        0, 0, 0, 5, 5, 0, 0, 0,
        -5, 0, 0, 0, 0, 0, 0, -5,
        -5, 0, 0, 0, 0, 0, 0, -5,
        -5, 0, 0, 0, 0, 0, 0, -5,
        -5, 0, 0, 0, 0, 0, 0, -5,
        -5, 0, 0, 0, 0, 0, 0, -5,
        5, 10, 10, 10, 10, 10, 10, 5,
        0, 0, 0, 0, 0, 0, 0, 0,
    ]
    static let queen: [Int] = [
        -20, -10, -10, -5, -5, -10, -10, -20,
        -10, 0, 5, 0, 0, 0, 0, -10,
        -10, 5, 5, 5, 5, 5, 0, -10,
        0, 0, 5, 5, 5, 5, 0, -5,
        -5, 0, 5, 5, 5, 5, 0, -5,
        -10, 0, 5, 5, 5, 5, 0, -10,
        -10, 0, 0, 0, 0, 0, 0, -10,
        -20, -10, -10, -5, -5, -10, -10, -20,
    ]
    /// King safety table: stay in the corner behind the pawn shield.
    static let kingMiddlegame: [Int] = [
        20, 30, 10, 0, 0, 10, 30, 20,
        20, 20, 0, 0, 0, 0, 20, 20,
        -10, -20, -20, -20, -20, -20, -20, -10,
        -20, -30, -30, -40, -40, -30, -30, -20,
        -30, -40, -40, -50, -50, -40, -40, -30,
        -30, -40, -40, -50, -50, -40, -40, -30,
        -30, -40, -40, -50, -50, -40, -40, -30,
        -30, -40, -40, -50, -50, -40, -40, -30,
    ]
    /// King activity table: march to the center where it helps escort pawns
    /// and attack the opponent's.
    static let kingEndgame: [Int] = [
        -50, -40, -30, -20, -20, -30, -40, -50,
        -30, -20, -10, 0, 0, -10, -20, -30,
        -30, -10, 20, 30, 30, 20, -10, -30,
        -30, -10, 30, 40, 40, 30, -10, -30,
        -30, -10, 30, 40, 40, 30, -10, -30,
        -30, -10, 20, 30, 30, 20, -10, -30,
        -30, -30, 0, 0, 0, 0, -30, -30,
        -50, -30, -30, -30, -30, -30, -30, -50,
    ]

    static func bonus(for piece: Piece, at square: Int) -> Int {
        let idx = mirroredIndex(square, color: piece.color)
        switch piece.kind {
        case .pawn: return pawn[idx]
        case .knight: return knight[idx]
        case .bishop: return bishop[idx]
        case .rook: return rook[idx]
        case .queen: return queen[idx]
        case .king: return kingMiddlegame[idx]
        }
    }

    static func kingBonus(at square: Int, color: PieceColor, table: [Int]) -> Int {
        table[mirroredIndex(square, color: color)]
    }

    /// Mirror vertically for black — tables above are written from White's perspective.
    private static func mirroredIndex(_ square: Int, color: PieceColor) -> Int {
        color == .white ? square : Sq.index(file: Sq.file(square), rank: 7 - Sq.rank(square))
    }
}
