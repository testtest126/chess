import Foundation

/// A full chess position: piece placement plus all state needed for legal move generation.
public struct Board: Equatable, Hashable, Sendable {
    /// 64 squares, index 0 = a1 ... 63 = h8.
    public private(set) var squares: [Piece?]
    public private(set) var sideToMove: PieceColor
    public private(set) var castlingRights: CastlingRights
    /// En passant target square (the square behind the pawn that just double-pushed), if any.
    public private(set) var enPassantSquare: Int?
    public private(set) var halfmoveClock: Int
    public private(set) var fullmoveNumber: Int

    public static let startingFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

    public init() {
        self.init(fen: Board.startingFEN)!
    }

    // MARK: - FEN

    public init?(fen: String) {
        let parts = fen.split(separator: " ")
        guard parts.count >= 4 else { return nil }

        var squares = [Piece?](repeating: nil, count: 64)
        let ranks = parts[0].split(separator: "/")
        guard ranks.count == 8 else { return nil }
        for (i, rankStr) in ranks.enumerated() {
            let rank = 7 - i
            var file = 0
            for ch in rankStr {
                if let skip = ch.wholeNumberValue, skip >= 1, skip <= 8 {
                    file += skip
                } else if let piece = Piece(fenChar: ch) {
                    guard file <= 7 else { return nil }
                    squares[Sq.index(file: file, rank: rank)] = piece
                    file += 1
                } else {
                    return nil
                }
            }
            guard file == 8 else { return nil }
        }

        guard let stm: PieceColor = parts[1] == "w" ? .white : (parts[1] == "b" ? .black : nil) else { return nil }
        guard let rights = CastlingRights(fenString: String(parts[2])) else { return nil }

        var ep: Int?
        if parts[3] != "-" {
            guard let sq = Sq.parse(parts[3]) else { return nil }
            ep = sq
        }

        let halfmove = parts.count > 4 ? Int(parts[4]) ?? 0 : 0
        let fullmove = parts.count > 5 ? Int(parts[5]) ?? 1 : 1

        self.squares = squares
        self.sideToMove = stm
        self.castlingRights = rights
        self.enPassantSquare = ep
        self.halfmoveClock = halfmove
        self.fullmoveNumber = fullmove
    }

    public var fen: String {
        var placement = ""
        for rank in (0...7).reversed() {
            var empty = 0
            for file in 0...7 {
                if let piece = squares[Sq.index(file: file, rank: rank)] {
                    if empty > 0 { placement += "\(empty)"; empty = 0 }
                    placement.append(piece.fenChar)
                } else {
                    empty += 1
                }
            }
            if empty > 0 { placement += "\(empty)" }
            if rank > 0 { placement += "/" }
        }
        let ep = enPassantSquare.map(Sq.name) ?? "-"
        return "\(placement) \(sideToMove == .white ? "w" : "b") \(castlingRights.fenString) \(ep) \(halfmoveClock) \(fullmoveNumber)"
    }

    /// Position identity for repetition detection (ignores clocks).
    public var repetitionKey: String {
        let ep = enPassantEffective.map(Sq.name) ?? "-"
        let placement = fen.split(separator: " ")[0]
        return "\(placement) \(sideToMove == .white ? "w" : "b") \(castlingRights.fenString) \(ep)"
    }

    /// EP square only counts for repetition if a legal EP capture actually exists.
    private var enPassantEffective: Int? {
        guard let ep = enPassantSquare else { return nil }
        for move in legalMoves() where move.to == ep {
            if let p = squares[move.from], p.kind == .pawn { return ep }
        }
        return nil
    }

    // MARK: - Piece access

    public subscript(square: Int) -> Piece? { squares[square] }

    public func kingSquare(of color: PieceColor) -> Int? {
        squares.firstIndex(of: Piece(color: color, kind: .king))
    }

    // MARK: - Attack detection

    private static let knightOffsets: [(Int, Int)] = [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)]
    private static let kingOffsets: [(Int, Int)] = [(0, 1), (1, 1), (1, 0), (1, -1), (0, -1), (-1, -1), (-1, 0), (-1, 1)]
    private static let bishopDirs: [(Int, Int)] = [(1, 1), (1, -1), (-1, -1), (-1, 1)]
    private static let rookDirs: [(Int, Int)] = [(0, 1), (1, 0), (0, -1), (-1, 0)]

    /// Is `square` attacked by any piece of `attacker`?
    public func isAttacked(_ square: Int, by attacker: PieceColor) -> Bool {
        let f = Sq.file(square), r = Sq.rank(square)

        // Pawn attacks: an enemy pawn attacks this square from the direction it moves *from*.
        let pawnDir = attacker == .white ? 1 : -1
        for df in [-1, 1] {
            let pf = f + df, pr = r - pawnDir
            if Sq.isValid(file: pf, rank: pr),
               squares[Sq.index(file: pf, rank: pr)] == Piece(color: attacker, kind: .pawn) {
                return true
            }
        }

        for (df, dr) in Board.knightOffsets {
            let nf = f + df, nr = r + dr
            if Sq.isValid(file: nf, rank: nr),
               squares[Sq.index(file: nf, rank: nr)] == Piece(color: attacker, kind: .knight) {
                return true
            }
        }

        for (df, dr) in Board.kingOffsets {
            let nf = f + df, nr = r + dr
            if Sq.isValid(file: nf, rank: nr),
               squares[Sq.index(file: nf, rank: nr)] == Piece(color: attacker, kind: .king) {
                return true
            }
        }

        for (df, dr) in Board.bishopDirs {
            var nf = f + df, nr = r + dr
            while Sq.isValid(file: nf, rank: nr) {
                if let p = squares[Sq.index(file: nf, rank: nr)] {
                    if p.color == attacker && (p.kind == .bishop || p.kind == .queen) { return true }
                    break
                }
                nf += df; nr += dr
            }
        }

        for (df, dr) in Board.rookDirs {
            var nf = f + df, nr = r + dr
            while Sq.isValid(file: nf, rank: nr) {
                if let p = squares[Sq.index(file: nf, rank: nr)] {
                    if p.color == attacker && (p.kind == .rook || p.kind == .queen) { return true }
                    break
                }
                nf += df; nr += dr
            }
        }

        return false
    }

    public func isInCheck(_ color: PieceColor) -> Bool {
        guard let king = kingSquare(of: color) else { return false }
        return isAttacked(king, by: color.opposite)
    }

    // MARK: - Move generation

    /// All pseudo-legal moves for the side to move (may leave own king in check).
    func pseudoLegalMoves() -> [Move] {
        var moves: [Move] = []
        moves.reserveCapacity(48)
        let us = sideToMove

        for from in 0..<64 {
            guard let piece = squares[from], piece.color == us else { continue }
            let f = Sq.file(from), r = Sq.rank(from)

            switch piece.kind {
            case .pawn:
                let dir = us == .white ? 1 : -1
                let startRank = us == .white ? 1 : 6
                let promoRank = us == .white ? 7 : 0

                // Single push
                let oneAhead = r + dir
                if Sq.isValid(file: f, rank: oneAhead), squares[Sq.index(file: f, rank: oneAhead)] == nil {
                    appendPawnMove(&moves, from: from, to: Sq.index(file: f, rank: oneAhead), promoRank: promoRank)
                    // Double push
                    if r == startRank, squares[Sq.index(file: f, rank: r + 2 * dir)] == nil {
                        moves.append(Move(from: from, to: Sq.index(file: f, rank: r + 2 * dir)))
                    }
                }
                // Captures
                for df in [-1, 1] {
                    let nf = f + df, nr = r + dir
                    guard Sq.isValid(file: nf, rank: nr) else { continue }
                    let to = Sq.index(file: nf, rank: nr)
                    if let target = squares[to], target.color != us {
                        appendPawnMove(&moves, from: from, to: to, promoRank: promoRank)
                    } else if to == enPassantSquare {
                        moves.append(Move(from: from, to: to))
                    }
                }

            case .knight:
                for (df, dr) in Board.knightOffsets {
                    let nf = f + df, nr = r + dr
                    guard Sq.isValid(file: nf, rank: nr) else { continue }
                    let to = Sq.index(file: nf, rank: nr)
                    if squares[to]?.color != us { moves.append(Move(from: from, to: to)) }
                }

            case .bishop:
                slide(&moves, from: from, dirs: Board.bishopDirs)
            case .rook:
                slide(&moves, from: from, dirs: Board.rookDirs)
            case .queen:
                slide(&moves, from: from, dirs: Board.bishopDirs + Board.rookDirs)

            case .king:
                for (df, dr) in Board.kingOffsets {
                    let nf = f + df, nr = r + dr
                    guard Sq.isValid(file: nf, rank: nr) else { continue }
                    let to = Sq.index(file: nf, rank: nr)
                    if squares[to]?.color != us { moves.append(Move(from: from, to: to)) }
                }
                // Castling
                let them = us.opposite
                let homeRank = us == .white ? 0 : 7
                if from == Sq.index(file: 4, rank: homeRank), !isAttacked(from, by: them) {
                    let kingside: CastlingRights = us == .white ? .whiteKingside : .blackKingside
                    let queenside: CastlingRights = us == .white ? .whiteQueenside : .blackQueenside
                    if castlingRights.contains(kingside),
                       squares[Sq.index(file: 5, rank: homeRank)] == nil,
                       squares[Sq.index(file: 6, rank: homeRank)] == nil,
                       !isAttacked(Sq.index(file: 5, rank: homeRank), by: them),
                       !isAttacked(Sq.index(file: 6, rank: homeRank), by: them) {
                        moves.append(Move(from: from, to: Sq.index(file: 6, rank: homeRank)))
                    }
                    if castlingRights.contains(queenside),
                       squares[Sq.index(file: 3, rank: homeRank)] == nil,
                       squares[Sq.index(file: 2, rank: homeRank)] == nil,
                       squares[Sq.index(file: 1, rank: homeRank)] == nil,
                       !isAttacked(Sq.index(file: 3, rank: homeRank), by: them),
                       !isAttacked(Sq.index(file: 2, rank: homeRank), by: them) {
                        moves.append(Move(from: from, to: Sq.index(file: 2, rank: homeRank)))
                    }
                }
            }
        }
        return moves
    }

    private func appendPawnMove(_ moves: inout [Move], from: Int, to: Int, promoRank: Int) {
        if Sq.rank(to) == promoRank {
            for kind in [PieceKind.queen, .rook, .bishop, .knight] {
                moves.append(Move(from: from, to: to, promotion: kind))
            }
        } else {
            moves.append(Move(from: from, to: to))
        }
    }

    private func slide(_ moves: inout [Move], from: Int, dirs: [(Int, Int)]) {
        let us = sideToMove
        let f = Sq.file(from), r = Sq.rank(from)
        for (df, dr) in dirs {
            var nf = f + df, nr = r + dr
            while Sq.isValid(file: nf, rank: nr) {
                let to = Sq.index(file: nf, rank: nr)
                if let target = squares[to] {
                    if target.color != us { moves.append(Move(from: from, to: to)) }
                    break
                }
                moves.append(Move(from: from, to: to))
                nf += df; nr += dr
            }
        }
    }

    /// All fully legal moves for the side to move.
    public func legalMoves() -> [Move] {
        pseudoLegalMoves().filter { move in
            var copy = self
            copy.apply(move)
            return !copy.isInCheck(sideToMove)
        }
    }

    public func legalMoves(from square: Int) -> [Move] {
        legalMoves().filter { $0.from == square }
    }

    public func isLegal(_ move: Move) -> Bool {
        legalMoves().contains(move)
    }

    // MARK: - Making moves

    /// Applies a move without legality checking. Used internally and by `making(_:)`.
    mutating func apply(_ move: Move) {
        guard let piece = squares[move.from] else { return }
        let us = piece.color
        let isCapture = squares[move.to] != nil
        let isPawn = piece.kind == .pawn

        // En passant capture: remove the captured pawn.
        if isPawn, move.to == enPassantSquare {
            let capturedRank = us == .white ? Sq.rank(move.to) - 1 : Sq.rank(move.to) + 1
            squares[Sq.index(file: Sq.file(move.to), rank: capturedRank)] = nil
        }

        // Castling: move the rook too.
        if piece.kind == .king, abs(Sq.file(move.to) - Sq.file(move.from)) == 2 {
            let rank = Sq.rank(move.from)
            if Sq.file(move.to) == 6 {
                squares[Sq.index(file: 5, rank: rank)] = squares[Sq.index(file: 7, rank: rank)]
                squares[Sq.index(file: 7, rank: rank)] = nil
            } else {
                squares[Sq.index(file: 3, rank: rank)] = squares[Sq.index(file: 0, rank: rank)]
                squares[Sq.index(file: 0, rank: rank)] = nil
            }
        }

        // Move the piece (with promotion).
        squares[move.from] = nil
        if let promo = move.promotion {
            squares[move.to] = Piece(color: us, kind: promo)
        } else {
            squares[move.to] = piece
        }

        // Update castling rights.
        if piece.kind == .king {
            castlingRights.subtract(us == .white ? [.whiteKingside, .whiteQueenside] : [.blackKingside, .blackQueenside])
        }
        for sq in [move.from, move.to] {
            switch sq {
            case 0: castlingRights.remove(.whiteQueenside)
            case 7: castlingRights.remove(.whiteKingside)
            case 56: castlingRights.remove(.blackQueenside)
            case 63: castlingRights.remove(.blackKingside)
            default: break
            }
        }

        // En passant target.
        if isPawn, abs(Sq.rank(move.to) - Sq.rank(move.from)) == 2 {
            enPassantSquare = Sq.index(file: Sq.file(move.from), rank: (Sq.rank(move.from) + Sq.rank(move.to)) / 2)
        } else {
            enPassantSquare = nil
        }

        // Clocks.
        if isPawn || isCapture {
            halfmoveClock = 0
        } else {
            halfmoveClock += 1
        }
        if us == .black { fullmoveNumber += 1 }
        sideToMove = us.opposite
    }

    /// Returns the position after a legal move, or nil if the move is illegal.
    public func making(_ move: Move) -> Board? {
        guard isLegal(move) else { return nil }
        var copy = self
        copy.apply(move)
        return copy
    }

    /// Used only by the evaluator to measure opponent mobility.
    mutating func flipSideForEvaluation() {
        sideToMove = sideToMove.opposite
        enPassantSquare = nil
    }

    // MARK: - Status

    public enum Status: Equatable, Sendable {
        case ongoing
        case checkmate(winner: PieceColor)
        case stalemate
        case fiftyMoveDraw
        case insufficientMaterial
    }

    public var status: Status {
        if legalMoves().isEmpty {
            return isInCheck(sideToMove) ? .checkmate(winner: sideToMove.opposite) : .stalemate
        }
        if halfmoveClock >= 100 { return .fiftyMoveDraw }
        if hasInsufficientMaterial { return .insufficientMaterial }
        return .ongoing
    }

    /// K vs K, K+B vs K, K+N vs K, K+B vs K+B (same-colored bishops).
    public var hasInsufficientMaterial: Bool {
        var minorSquares: [(PieceColor, PieceKind, Int)] = []
        for (i, piece) in squares.enumerated() {
            guard let piece, piece.kind != .king else { continue }
            switch piece.kind {
            case .pawn, .rook, .queen: return false
            case .knight, .bishop: minorSquares.append((piece.color, piece.kind, i))
            case .king: break
            }
        }
        switch minorSquares.count {
        case 0, 1: return true
        case 2:
            let (c1, k1, s1) = minorSquares[0]
            let (c2, k2, s2) = minorSquares[1]
            // Two bishops on same color squares, opposite sides: dead draw.
            return c1 != c2 && k1 == .bishop && k2 == .bishop && Sq.isLight(s1) == Sq.isLight(s2)
        default: return false
        }
    }

    // MARK: - SAN

    /// Standard algebraic notation for a legal move in this position.
    public func san(for move: Move) -> String {
        guard let piece = squares[move.from] else { return move.uci }
        var result: String

        if piece.kind == .king, abs(Sq.file(move.to) - Sq.file(move.from)) == 2 {
            result = Sq.file(move.to) == 6 ? "O-O" : "O-O-O"
        } else {
            let isCapture = squares[move.to] != nil || (piece.kind == .pawn && move.to == enPassantSquare)
            var disambiguation = ""

            if piece.kind != .pawn {
                let rivals = legalMoves().filter {
                    $0.to == move.to && $0.from != move.from && squares[$0.from]?.kind == piece.kind
                }
                if !rivals.isEmpty {
                    let sameFile = rivals.contains { Sq.file($0.from) == Sq.file(move.from) }
                    let sameRank = rivals.contains { Sq.rank($0.from) == Sq.rank(move.from) }
                    if !sameFile {
                        disambiguation = String(Sq.name(move.from).first!)
                    } else if !sameRank {
                        disambiguation = String(Sq.rank(move.from) + 1)
                    } else {
                        disambiguation = Sq.name(move.from)
                    }
                }
            }

            result = piece.kind.letter + disambiguation
            if isCapture {
                if piece.kind == .pawn { result += String(Sq.name(move.from).first!) }
                result += "x"
            }
            result += Sq.name(move.to)
            if let promo = move.promotion { result += "=" + promo.letter }
        }

        var next = self
        next.apply(move)
        switch next.status {
        case .checkmate: result += "#"
        default: if next.isInCheck(next.sideToMove) { result += "+" }
        }
        return result
    }

    // MARK: - Evaluation (heuristic, for game review)

    /// Static evaluation in centipawns from White's perspective.
    /// Material + piece-square tables + mobility. Not a real engine — good enough
    /// for post-game review graphs and blunder flagging.
    public func evaluate() -> Int {
        switch status {
        case .checkmate(let winner): return winner == .white ? 100_000 : -100_000
        case .stalemate, .fiftyMoveDraw, .insufficientMaterial: return 0
        case .ongoing: break
        }

        var score = 0
        for (i, piece) in squares.enumerated() {
            guard let piece else { continue }
            var value = piece.kind.centipawnValue
            value += PST.bonus(for: piece, at: i)
            score += piece.color == .white ? value : -value
        }

        // Mobility (small nudge).
        var mobilityBoard = self
        let myMobility = mobilityBoard.pseudoLegalMoves().count
        mobilityBoard.flipSideForEvaluation()
        let theirMobility = mobilityBoard.pseudoLegalMoves().count
        let mobilityDiff = sideToMove == .white ? myMobility - theirMobility : theirMobility - myMobility
        score += mobilityDiff * 2

        return score
    }

    /// One-ply-deep "best reply aware" evaluation: minimax over legal moves using static eval.
    /// From White's perspective. Used for review accuracy classification.
    public func evaluateWithLookahead() -> Int {
        let moves = legalMoves()
        if moves.isEmpty { return evaluate() }
        var best = sideToMove == .white ? Int.min : Int.max
        for move in moves {
            var next = self
            next.apply(move)
            let value = next.evaluate()
            if sideToMove == .white { best = max(best, value) } else { best = min(best, value) }
        }
        return best
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
    static let king: [Int] = [
        20, 30, 10, 0, 0, 10, 30, 20,
        20, 20, 0, 0, 0, 0, 20, 20,
        -10, -20, -20, -20, -20, -20, -20, -10,
        -20, -30, -30, -40, -40, -30, -30, -20,
        -30, -40, -40, -50, -50, -40, -40, -30,
        -30, -40, -40, -50, -50, -40, -40, -30,
        -30, -40, -40, -50, -50, -40, -40, -30,
        -30, -40, -40, -50, -50, -40, -40, -30,
    ]

    static func bonus(for piece: Piece, at square: Int) -> Int {
        // Mirror vertically for black.
        let idx = piece.color == .white ? square : Sq.index(file: Sq.file(square), rank: 7 - Sq.rank(square))
        switch piece.kind {
        case .pawn: return pawn[idx]
        case .knight: return knight[idx]
        case .bishop: return bishop[idx]
        case .rook: return rook[idx]
        case .queen: return queen[idx]
        case .king: return king[idx]
        }
    }
}
