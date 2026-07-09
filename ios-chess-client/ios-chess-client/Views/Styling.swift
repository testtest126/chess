import SwiftUI

// App-wide styling helpers. The app targets iOS 17, so Liquid Glass button
// styles (iOS 26) are adopted behind availability checks and degrade to the
// standard bordered styles on older systems.

extension View {
    /// Primary call-to-action style: Liquid Glass on iOS 26+, prominent
    /// bordered elsewhere. Always large.
    @ViewBuilder
    func primaryActionButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent).controlSize(.large)
        } else {
            self.buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    /// Secondary action style: Liquid Glass on iOS 26+, bordered elsewhere.
    @ViewBuilder
    func secondaryActionButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass).controlSize(.large)
        } else {
            self.buttonStyle(.bordered).controlSize(.large)
        }
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