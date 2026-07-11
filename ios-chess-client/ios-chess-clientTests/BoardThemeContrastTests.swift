import Testing
import SwiftUI
import UIKit
@testable import ios_chess_client

/// WCAG 2.1 contrast for the board's coordinate labels (audit #83, P2.4).
/// Light squares must clear AA for small text (4.5:1) with the theme's
/// label color. Mid-tone dark squares mathematically cannot reach 4.5:1
/// with any text color, so they use white — asserted here at >= 3.0:1
/// (the AA large-text floor) — plus a halo shadow in the board view.
/// @MainActor: BoardTheme inherits the app target's MainActor default
/// isolation under Swift 6; the test target's default is nonisolated.
@MainActor
struct BoardThemeContrastTests {

    private func rgb(_ color: Color) -> (Double, Double, Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }

    private func luminance(_ c: (Double, Double, Double)) -> Double {
        func channel(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.0) + 0.7152 * channel(c.1) + 0.0722 * channel(c.2)
    }

    private func contrast(_ a: Color, _ b: Color) -> Double {
        let (l1, l2) = (luminance(rgb(a)), luminance(rgb(b)))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    @Test(arguments: BoardTheme.allCases)
    func lightSquareLabelsMeetAASmallText(theme: BoardTheme) {
        let ratio = contrast(theme.coordinateColor(onLight: true), theme.lightSquare)
        #expect(ratio >= 4.5, "\(theme.rawValue) on-light label ratio \(ratio)")
    }

    @Test(arguments: BoardTheme.allCases)
    func darkSquareLabelsMeetLargeTextFloor(theme: BoardTheme) {
        let ratio = contrast(theme.coordinateColor(onLight: false), theme.darkSquare)
        #expect(ratio >= 3.0, "\(theme.rawValue) on-dark label ratio \(ratio)")
    }

    /// The old scheme (opposite square color) is what the audit flagged;
    /// this documents that the new scheme strictly improves every theme.
    @Test(arguments: BoardTheme.allCases)
    func newSchemeBeatsOldSchemeEverywhere(theme: BoardTheme) {
        let oldOnLight = contrast(theme.darkSquare, theme.lightSquare)
        let newOnLight = contrast(theme.coordinateColor(onLight: true), theme.lightSquare)
        let oldOnDark = contrast(theme.lightSquare, theme.darkSquare)
        let newOnDark = contrast(theme.coordinateColor(onLight: false), theme.darkSquare)
        #expect(newOnLight > oldOnLight)
        #expect(newOnDark > oldOnDark)
    }
}
