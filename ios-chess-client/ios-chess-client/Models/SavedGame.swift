import Foundation
import SwiftData
import ChessKit

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

    init(
        date: Date,
        playerColor: PieceColor,
        difficulty: Difficulty?,
        result: Game.Result,
        endReason: Game.EndReason?,
        uciMoves: [String],
        opponentName: String? = nil
    ) {
        self.date = date
        self.playerColorRaw = playerColor.rawValue
        self.difficultyRaw = difficulty?.rawValue ?? "online"
        self.resultRaw = result.rawValue
        self.endReasonRaw = endReason?.rawValue
        self.moveCount = uciMoves.count
        self.uciMoves = uciMoves.joined(separator: " ")
        self.opponentName = opponentName
    }

    var playerColor: PieceColor { PieceColor(rawValue: playerColorRaw) ?? .white }
    var difficulty: Difficulty? { Difficulty(rawValue: difficultyRaw) }

    /// "Engine (Club)" for local games, the opponent's name for online ones.
    var opponentDescription: String {
        if let opponentName { return opponentName }
        if let difficulty { return "Engine (\(difficulty.label))" }
        return "Opponent"
    }
    var result: Game.Result { Game.Result(rawValue: resultRaw) ?? .ongoing }
    var endReason: Game.EndReason? { endReasonRaw.flatMap(Game.EndReason.init(rawValue:)) }
    var moves: [String] { uciMoves.split(separator: " ").map(String.init) }

    /// "Won", "Lost", or "Draw" from the player's perspective.
    var playerOutcome: String {
        switch result {
        case .draw: return "Draw"
        case .whiteWins: return playerColor == .white ? "Won" : "Lost"
        case .blackWins: return playerColor == .black ? "Won" : "Lost"
        case .ongoing: return "Unfinished"
        }
    }

    var endReasonDescription: String {
        switch endReason {
        case .checkmate: return "by checkmate"
        case .stalemate: return "by stalemate"
        case .resignation: return "by resignation"
        case .timeout: return "on time"
        case .drawAgreement: return "by agreement"
        case .fiftyMoveRule: return "by 50-move rule"
        case .threefoldRepetition: return "by repetition"
        case .insufficientMaterial: return "by insufficient material"
        case .abandoned: return "abandoned"
        case nil: return ""
        }
    }
}
