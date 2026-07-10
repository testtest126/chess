import Foundation
import ChessKit

/// Localized display names for chess primitives from ChessKit, which stores
/// its enums with fixed English raw values. Kept in the app layer so the
/// rules library stays free of presentation and localization concerns.

extension PieceColor {
    /// "White" / "Black", localized for display and VoiceOver.
    var localizedName: String {
        switch self {
        case .white: return String(localized: "White", comment: "Chess piece color")
        case .black: return String(localized: "Black", comment: "Chess piece color")
        }
    }
}

extension PieceKind {
    /// "Queen", "Knight", … localized for the promotion picker and VoiceOver.
    var localizedName: String {
        switch self {
        case .king: return String(localized: "King", comment: "Chess piece")
        case .queen: return String(localized: "Queen", comment: "Chess piece")
        case .rook: return String(localized: "Rook", comment: "Chess piece")
        case .bishop: return String(localized: "Bishop", comment: "Chess piece")
        case .knight: return String(localized: "Knight", comment: "Chess piece")
        case .pawn: return String(localized: "Pawn", comment: "Chess piece")
        }
    }
}
