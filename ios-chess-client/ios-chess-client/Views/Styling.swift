import SwiftUI
import ChessOnline

// App-wide styling helpers. The app targets iOS 17, so Liquid Glass button
// styles (iOS 26) are adopted behind availability checks and degrade to the
// standard bordered styles on older systems.

extension TimeControl {
    /// The lobby picker's UserDefaults key (stores the rawValue).
    static let storageKey = "preferred_time_control"

    /// Speed name shown in pickers and titles ("Bullet", "Blitz", "Rapid").
    var label: String {
        switch self {
        case .bullet: return String(localized: "Bullet", comment: "Time control speed")
        case .blitz: return String(localized: "Blitz", comment: "Time control speed")
        case .rapid: return String(localized: "Rapid", comment: "Time control speed")
        }
    }

    /// Name plus conventional notation, e.g. "Blitz 5+3".
    var displayName: String { "\(label) \(shortLabel)" }
}

extension View {
    /// Primary call-to-action style: Liquid Glass on iOS 26+, prominent
    /// bordered elsewhere. Always large.
    ///
    /// The `#if compiler` gate matters: `.glassProminent` only exists in the
    /// iOS 26 SDK (Xcode 26 / Swift 6.2+). `#available` is a runtime check,
    /// so without the compile-time gate this file fails to build on older
    /// toolchains — such as CI runners still on Xcode 16.
    @ViewBuilder
    func primaryActionButtonStyle() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent).controlSize(.large)
                .modifier(BrandCTALabelColor())
        } else {
            self.buttonStyle(.borderedProminent).controlSize(.large)
                .modifier(BrandCTALabelColor())
        }
        #else
        self.buttonStyle(.borderedProminent).controlSize(.large)
            .modifier(BrandCTALabelColor())
        #endif
    }

    /// Secondary action style: Liquid Glass on iOS 26+, bordered elsewhere.
    @ViewBuilder
    func secondaryActionButtonStyle() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass).controlSize(.large)
        } else {
            self.buttonStyle(.bordered).controlSize(.large)
        }
        #else
        self.buttonStyle(.bordered).controlSize(.large)
        #endif
    }

    /// Card backdrop for player bars and summary blocks — a thin material so
    /// it adapts to light/dark and sits naturally alongside Liquid Glass.
    func playerCardStyle() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Label color for the brand-gold primary CTAs (#117). The light-mode brass
/// carries white at large-text AA contrast; the brighter dark-mode gold
/// would land under 2:1 with white, so it takes near-black instead. Applied
/// by `primaryActionButtonStyle()` so every screen's CTA agrees.
///
/// Disabled buttons are left alone: forcing a color there would override
/// the system style's dimmed label and make a disabled CTA read as active
/// (e.g. Play Online while a sign-in is in flight).
private struct BrandCTALabelColor: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.foregroundStyle(colorScheme == .dark ? Color(white: 0.12) : .white)
        } else {
            content
        }
    }
}
