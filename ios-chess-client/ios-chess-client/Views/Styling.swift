import SwiftUI
import ChessOnline

// App-wide styling helpers. The app targets iOS 17, so Liquid Glass button
// styles (iOS 26) are adopted behind availability checks and degrade to the
// standard bordered styles on older systems.

extension TimeControl {
    /// Speed name shown in pickers and titles ("Bullet", "Blitz", "Rapid").
    var label: String { rawValue.capitalized }

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
        } else {
            self.buttonStyle(.borderedProminent).controlSize(.large)
        }
        #else
        self.buttonStyle(.borderedProminent).controlSize(.large)
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