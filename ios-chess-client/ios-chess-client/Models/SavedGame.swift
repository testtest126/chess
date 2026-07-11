import Foundation
import SwiftData
import ChessKit
import ChessOnline

/// A finished game persisted for the history list and post-game review.
/// Stores moves as space-separated UCI so the full `Game` can be rebuilt.
@Model
final class SavedGame {
    var date: Date
    var playerColorRaw: String
    /// Engine difficulty for local games; "online" for online matches.
    var difficultyRaw: String
    var resultRaw: String
    var endReasonRaw: String?
    var moveCount: Int
    var uciMoves: String
    /// Set for online games only.
    var opponentName: String?
    /// The server's GameRecord id, used to dedupe against GET /games history.
    /// Nil for engine games and for online rows saved before this existed.
    var onlineGameID: UUID?
    /// Raw TimeControl value for online games; nil for engine games and rows
    /// that predate selectable controls.
    var timeControlRaw: String?

    init(
        date: Date,
        playerColor: PieceColor,
        difficulty: Difficulty?,
        result: Game.Result,
        endReason: Game.EndReason?,
        uciMoves: [String],
        opponentName: String? = nil,
        onlineGameID: UUID? = nil,
        timeControl: TimeControl? = nil
    ) {
        self.date = date
        self.playerColorRaw = playerColor.rawValue
        self.difficultyRaw = difficulty?.rawValue ?? "online"
        self.resultRaw = result.rawValue
        self.endReasonRaw = endReason?.rawValue
        self.moveCount = uciMoves.count
        self.uciMoves = uciMoves.joined(separator: " ")
        self.opponentName = opponentName
        self.onlineGameID = onlineGameID
        self.timeControlRaw = timeControl?.rawValue
    }

    var playerColor: PieceColor { PieceColor(rawValue: playerColorRaw) ?? .white }
    var difficulty: Difficulty? { Difficulty(rawValue: difficultyRaw) }
    var timeControl: TimeControl? { timeControlRaw.flatMap(TimeControl.init(rawValue:)) }

    /// "Engine (Club)" for local games, the opponent's name for online ones.
    var opponentDescription: String {
        if let opponentName { return opponentName }
        if let difficulty {
            return String(localized: "Engine (\(difficulty.label))",
                          comment: "Opponent in a local game; parameter is the difficulty name")
        }
        return String(localized: "Opponent", comment: "Fallback name shown until the opponent's real name arrives")
    }

    var result: Game.Result { Game.Result(rawValue: resultRaw) ?? .ongoing }
    var endReason: Game.EndReason? { endReasonRaw.flatMap(Game.EndReason.init(rawValue:)) }
    var moves: [String] { uciMoves.split(separator: " ").map(String.init) }

    /// "Won", "Lost", or "Draw" from the player's perspective.
    var playerOutcome: String {
        switch result {
        case .draw: return String(localized: "Draw", comment: "Draw game result")
        case .whiteWins:
            return playerColor == .white
                ? String(localized: "Won", comment: "Game outcome in the history list")
                : String(localized: "Lost", comment: "Game outcome in the history list")
        case .blackWins:
            return playerColor == .black
                ? String(localized: "Won", comment: "Game outcome in the history list")
                : String(localized: "Lost", comment: "Game outcome in the history list")
        case .ongoing: return String(localized: "Unfinished", comment: "Game outcome in the history list")
        }
    }

    var endReasonDescription: String {
        switch endReason {
        case .checkmate: return String(localized: "by checkmate", comment: "How a game ended, follows the outcome")
        case .stalemate: return String(localized: "by stalemate", comment: "How a game ended, follows the outcome")
        case .resignation: return String(localized: "by resignation", comment: "How a game ended, follows the outcome")
        case .timeout: return String(localized: "on time", comment: "How a game ended (ran out of clock), follows the outcome")
        case .drawAgreement: return String(localized: "by agreement", comment: "How a game ended, follows the outcome")
        case .fiftyMoveRule: return String(localized: "by 50-move rule", comment: "How a game ended, follows the outcome")
        case .threefoldRepetition: return String(localized: "by repetition", comment: "How a game ended, follows the outcome")
        case .insufficientMaterial: return String(localized: "by insufficient material", comment: "How a game ended, follows the outcome")
        case .abandoned: return String(localized: "abandoned", comment: "How a game ended, follows the outcome")
        case nil: return ""
        }
    }
}
