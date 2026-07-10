import SwiftUI

/// Square color presets for the board. The selection is stored in
/// UserDefaults (see `BoardTheme.storageKey`) and read by every board.
enum BoardTheme: String, CaseIterable, Identifiable {
    case classic, green, blue, gray

    static let storageKey = "board_theme"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .classic: return String(localized: "Classic", comment: "Board color theme")
        case .green: return String(localized: "Green", comment: "Board color theme")
        case .blue: return String(localized: "Blue", comment: "Board color theme")
        case .gray: return String(localized: "Gray", comment: "Board color theme")
        }
    }

    var lightSquare: Color {
        switch self {
        case .classic: return Color(red: 0.94, green: 0.85, blue: 0.71)
        case .green: return Color(red: 0.93, green: 0.93, blue: 0.82)
        case .blue: return Color(red: 0.87, green: 0.90, blue: 0.93)
        case .gray: return Color(red: 0.88, green: 0.88, blue: 0.88)
        }
    }

    var darkSquare: Color {
        switch self {
        case .classic: return Color(red: 0.71, green: 0.53, blue: 0.39)
        case .green: return Color(red: 0.46, green: 0.59, blue: 0.34)
        case .blue: return Color(red: 0.42, green: 0.55, blue: 0.68)
        case .gray: return Color(red: 0.55, green: 0.55, blue: 0.57)
        }
    }
}
