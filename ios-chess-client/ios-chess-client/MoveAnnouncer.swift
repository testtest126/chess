import SwiftUI
import ChessKit

/// VoiceOver narration for board changes. Raw SAN ("Nf3", "exd5+") is
/// unreadable when spoken, so announcements are built from the move itself:
/// "White: Knight to f3, check". Posting when VoiceOver is off is a no-op.
@MainActor
enum MoveAnnouncer {
    /// Announce the latest move in `game` (call when the move count grows).
    static func announceLastMove(in game: Game) {
        guard let entry = game.history.last else { return }
        AccessibilityNotification.Announcement(spokenDescription(of: entry)).post()
    }

    /// Announce that the last move was undone (engine games' Take Back).
    static func announceTakeback() {
        AccessibilityNotification.Announcement(
            String(localized: "Move taken back", comment: "VoiceOver announcement after undoing a move")
        ).post()
    }

    /// "White: Knight to f3, check" / "Black: pawn takes on d5" /
    /// "White: castles kingside" / "Black: pawn promotes to Queen on e1".
    /// Built from the entry rather than SAN so every part localizes.
    static func spokenDescription(of entry: Game.HistoryEntry) -> String {
        // The entry's board is the position after the move: the mover is the
        // side that is no longer to move, and the moved piece sits on `to`.
        let mover = entry.board.sideToMove.opposite.localizedName
        let destination = Sq.name(entry.move.to)
        let captures = entry.san.contains("x")

        var body: String
        if entry.san.hasPrefix("O-O-O") {
            body = String(localized: "\(mover): castles queenside",
                          comment: "VoiceOver move announcement")
        } else if entry.san.hasPrefix("O-O") {
            body = String(localized: "\(mover): castles kingside",
                          comment: "VoiceOver move announcement")
        } else if let promoted = entry.move.promotion {
            body = captures
                ? String(localized: "\(mover): pawn takes and promotes to \(promoted.localizedName) on \(destination)",
                         comment: "VoiceOver move announcement")
                : String(localized: "\(mover): pawn promotes to \(promoted.localizedName) on \(destination)",
                         comment: "VoiceOver move announcement")
        } else {
            let piece = entry.board[entry.move.to]?.kind.localizedName
                ?? String(localized: "piece", comment: "Fallback piece name in a VoiceOver move announcement")
            body = captures
                ? String(localized: "\(mover): \(piece) takes on \(destination)",
                         comment: "VoiceOver move announcement")
                : String(localized: "\(mover): \(piece) to \(destination)",
                         comment: "VoiceOver move announcement")
        }

        if entry.san.hasSuffix("#") {
            body += String(localized: ", checkmate", comment: "VoiceOver move announcement suffix")
        } else if entry.san.hasSuffix("+") {
            body += String(localized: ", check", comment: "VoiceOver move announcement suffix")
        }
        return body
    }
}
