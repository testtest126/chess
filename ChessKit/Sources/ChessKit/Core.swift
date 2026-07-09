import Foundation

// MARK: - Colors & Pieces

public enum PieceColor: String, Codable, Sendable, CaseIterable, Hashable {
    case white, black

    public var opposite: PieceColor { self == .white ? .black : .white }
}

public enum PieceKind: String, Codable, Sendable, CaseIterable, Hashable {
    case pawn, knight, bishop, rook, queen, king

    /// Uppercase SAN letter. Empty for pawns.
    public var letter: String {
        switch self {
        case .pawn: return ""
        case .knight: return "N"
        case .bishop: return "B"
        case .rook: return "R"
        case .queen: return "Q"
        case .king: return "K"
        }
    }

    public var centipawnValue: Int {
        switch self {
        case .pawn: return 100
        case .knight: return 320
        case .bishop: return 330
        case .rook: return 500
        case .queen: return 900
        case .king: return 0
        }
    }
}

public struct Piece: Equatable, Hashable, Codable, Sendable {
    public var color: PieceColor
    public var kind: PieceKind

    public init(color: PieceColor, kind: PieceKind) {
        self.color = color
        self.kind = kind
    }

    public var fenChar: Character {
        let c: Character
        switch kind {
        case .pawn: c = "p"
        case .knight: c = "n"
        case .bishop: c = "b"
        case .rook: c = "r"
        case .queen: c = "q"
        case .king: c = "k"
        }
        return color == .white ? Character(c.uppercased()) : c
    }

    public init?(fenChar: Character) {
        let color: PieceColor = fenChar.isUppercase ? .white : .black
        switch Character(fenChar.lowercased()) {
        case "p": self = Piece(color: color, kind: .pawn)
        case "n": self = Piece(color: color, kind: .knight)
        case "b": self = Piece(color: color, kind: .bishop)
        case "r": self = Piece(color: color, kind: .rook)
        case "q": self = Piece(color: color, kind: .queen)
        case "k": self = Piece(color: color, kind: .king)
        default: return nil
        }
    }
}

// MARK: - Squares

/// Squares are Ints 0...63. a1 = 0, b1 = 1, ..., h1 = 7, a2 = 8, ..., h8 = 63.
public enum Sq {
    @inlinable public static func file(_ s: Int) -> Int { s & 7 }
    @inlinable public static func rank(_ s: Int) -> Int { s >> 3 }
    @inlinable public static func index(file: Int, rank: Int) -> Int { rank << 3 | file }
    @inlinable public static func isValid(file: Int, rank: Int) -> Bool {
        file >= 0 && file <= 7 && rank >= 0 && rank <= 7
    }

    /// True if the square is light-colored (h1 is light).
    public static func isLight(_ s: Int) -> Bool { (file(s) + rank(s)) % 2 == 1 }

    public static func name(_ s: Int) -> String {
        let files = "abcdefgh"
        let f = files[files.index(files.startIndex, offsetBy: file(s))]
        return "\(f)\(rank(s) + 1)"
    }

    public static func parse(_ name: some StringProtocol) -> Int? {
        guard name.count == 2 else { return nil }
        let chars = Array(name)
        guard let f = "abcdefgh".firstIndex(of: chars[0]),
              let r = chars[1].wholeNumberValue, r >= 1, r <= 8 else { return nil }
        return index(file: "abcdefgh".distance(from: "abcdefgh".startIndex, to: f), rank: r - 1)
    }
}

// MARK: - Castling rights

public struct CastlingRights: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let whiteKingside = CastlingRights(rawValue: 1 << 0)
    public static let whiteQueenside = CastlingRights(rawValue: 1 << 1)
    public static let blackKingside = CastlingRights(rawValue: 1 << 2)
    public static let blackQueenside = CastlingRights(rawValue: 1 << 3)
    public static let all: CastlingRights = [.whiteKingside, .whiteQueenside, .blackKingside, .blackQueenside]

    public var fenString: String {
        if isEmpty { return "-" }
        var s = ""
        if contains(.whiteKingside) { s += "K" }
        if contains(.whiteQueenside) { s += "Q" }
        if contains(.blackKingside) { s += "k" }
        if contains(.blackQueenside) { s += "q" }
        return s
    }

    public init?(fenString: String) {
        var rights: CastlingRights = []
        if fenString != "-" {
            for ch in fenString {
                switch ch {
                case "K": rights.insert(.whiteKingside)
                case "Q": rights.insert(.whiteQueenside)
                case "k": rights.insert(.blackKingside)
                case "q": rights.insert(.blackQueenside)
                default: return nil
                }
            }
        }
        self = rights
    }
}

// MARK: - Moves

public struct Move: Equatable, Hashable, Codable, Sendable {
    public var from: Int
    public var to: Int
    public var promotion: PieceKind?

    public init(from: Int, to: Int, promotion: PieceKind? = nil) {
        self.from = from
        self.to = to
        self.promotion = promotion
    }

    /// UCI long algebraic notation, e.g. "e2e4", "e7e8q".
    public var uci: String {
        var s = Sq.name(from) + Sq.name(to)
        switch promotion {
        case .knight: s += "n"
        case .bishop: s += "b"
        case .rook: s += "r"
        case .queen: s += "q"
        default: break
        }
        return s
    }

    public init?(uci: String) {
        guard uci.count == 4 || uci.count == 5 else { return nil }
        let chars = Array(uci)
        guard let from = Sq.parse(String(chars[0...1])),
              let to = Sq.parse(String(chars[2...3])) else { return nil }
        var promotion: PieceKind?
        if uci.count == 5 {
            switch chars[4] {
            case "q": promotion = .queen
            case "r": promotion = .rook
            case "b": promotion = .bishop
            case "n": promotion = .knight
            default: return nil
            }
        }
        self.init(from: from, to: to, promotion: promotion)
    }
}
