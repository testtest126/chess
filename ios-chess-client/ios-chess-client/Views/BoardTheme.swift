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

    /// Coordinate-label color for a square. The old scheme used the opposite
    /// square color, which lands at 2.3-2.8:1 on every theme (audit #83,
    /// finding P2.4). On light squares these are the theme's dark color
    /// darkened until it clears WCAG AA 4.5:1 (verified by unit test). The
    /// mid-tone dark squares can't reach 4.5:1 with any text color (white
    /// tops out near 3.5:1), so they use white, and the board view backs it
    /// with a dark halo shadow for pixel-level separation.
    func coordinateColor(onLight: Bool) -> Color {
        guard onLight else { return .white }
        switch self {
        case .classic: return Color(red: 0.46, green: 0.34, blue: 0.25)
        case .green: return Color(red: 0.32, green: 0.41, blue: 0.24)
        case .blue: return Color(red: 0.29, green: 0.38, blue: 0.48)
        case .gray: return Color(red: 0.38, green: 0.38, blue: 0.40)
        }
    }
}
