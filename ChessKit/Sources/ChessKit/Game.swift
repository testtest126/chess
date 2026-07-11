import Foundation

/// A complete game: a sequence of positions with move history, draw tracking, and results.
public struct Game: Sendable {
    public struct HistoryEntry: Sendable {
        public let move: Move
        public let san: String
        /// Position *after* the move.
        public let board: Board
    }

    public enum Result: String, Codable, Sendable {
        case whiteWins = "1-0"
        case blackWins = "0-1"
        case draw = "1/2-1/2"
        case ongoing = "*"
    }

    public enum EndReason: String, Codable, Sendable {
        case checkmate, stalemate, resignation, timeout, drawAgreement
        case fiftyMoveRule, threefoldRepetition, insufficientMaterial, abandoned
    }

    public private(set) var board: Board
    public private(set) var history: [HistoryEntry] = []
    public private(set) var result: Result = .ongoing
    public private(set) var endReason: EndReason?
    private var repetitionCounts: [String: Int]

    public init(board: Board = Board()) {
        self.board = board
        self.repetitionCounts = [board.repetitionKey: 1]
    }

    public var sideToMove: PieceColor { board.sideToMove }
    public var isOver: Bool { result != .ongoing }
    public var moveCount: Int { history.count }

    /// All positions from the start, including the initial one. history.count + 1 entries.
    public var positions: [Board] {
        var result = [initialBoard]
        result.append(contentsOf: history.map(\.board))
        return result
    }

    private var initialBoard: Board {
        // Reconstruct: first history entry's board minus the move isn't storable,
        // so we track it explicitly.
        _initialBoard
    }

    private var _initialBoard: Board = Board()

    public init(fen: String) throws {
        guard let board = Board(fen: fen) else { throw ChessError.invalidFEN }
        self.init(board: board)
        self._initialBoard = board
    }

    /// Attempts to play a move. Throws if illegal or game is over.
    @discardableResult
    public mutating func play(_ move: Move) throws -> HistoryEntry {
        guard !isOver else { throw ChessError.gameOver }
        guard board.isLegal(move) else { throw ChessError.illegalMove }

        let san = board.san(for: move)
        var next = board
        next.apply(move)

        let entry = HistoryEntry(move: move, san: san, board: next)
        history.append(entry)
        board = next

        let key = next.repetitionKey
        repetitionCounts[key, default: 0] += 1

        // Automatic terminal conditions.
        switch next.status {
        case .checkmate(let winner):
            result = winner == .white ? .whiteWins : .blackWins
            endReason = .checkmate
        case .stalemate:
            result = .draw
            endReason = .stalemate
        case .fiftyMoveDraw:
            result = .draw
            endReason = .fiftyMoveRule
        case .insufficientMaterial:
            result = .draw
            endReason = .insufficientMaterial
        case .ongoing:
            if repetitionCounts[key, default: 0] >= 3 {
                result = .draw
                endReason = .threefoldRepetition
            }
        }
        return entry
    }

    @discardableResult
    public mutating func play(uci: String) throws -> HistoryEntry {
        guard let move = Move(uci: uci) else { throw ChessError.invalidMove }
        // Normalize: a promotion move arriving without a promotion piece defaults to queen
        // only if the bare move isn't legal but the queen promotion is.
        if !board.isLegal(move), move.promotion == nil {
            let promoted = Move(from: move.from, to: move.to, promotion: .queen)
            if board.isLegal(promoted) { return try play(promoted) }
        }
        return try play(move)
    }

    /// Ends the game for an external reason (resignation, timeout, draw agreement, abandonment).
    public mutating func end(result: Result, reason: EndReason) {
        guard !isOver else { return }
        self.result = result
        self.endReason = reason
    }

    // MARK: - PGN

    public func pgn(white: String = "?", black: String = "?", event: String = "Casual Game", date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        formatter.timeZone = TimeZone(identifier: "UTC")

        var pgn = """
        [Event "\(event)"]
        [Site "MateMate"]
        [Date "\(formatter.string(from: date))"]
        [White "\(white)"]
        [Black "\(black)"]
        [Result "\(result.rawValue)"]

        """
        pgn += "\n"

        var line = ""
        for (i, entry) in history.enumerated() {
            if i % 2 == 0 { line += "\(i / 2 + 1). " }
            line += entry.san + " "
        }
        line += result.rawValue
        pgn += line + "\n"
        return pgn
    }

    /// Moves in UCI notation, space-separated. Compact wire/storage format.
    public var uciMoves: [String] { history.map(\.move.uci) }

    /// Rebuild a game from a list of UCI moves.
    public static func from(uciMoves: [String], fen: String? = nil) throws -> Game {
        var game: Game
        if let fen {
            game = try Game(fen: fen)
        } else {
            game = Game()
        }
        for uci in uciMoves {
            try game.play(uci: uci)
        }
        return game
    }
}

public enum ChessError: Error, Equatable, Sendable {
    case invalidFEN
    case invalidMove
    case illegalMove
    case gameOver
}
