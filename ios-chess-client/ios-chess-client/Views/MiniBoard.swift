import SwiftUI
import ChessKit

/// Non-interactive 8×8 miniature of a position, used for history-row
/// thumbnails (#117). `BoardView` is deliberately not reused here: its
/// gestures, move hints, and per-square accessibility do real work that a
/// 56pt decoration must skip entirely.
struct MiniBoard: View {
    let board: Board
    let theme: BoardTheme

    var body: some View {
        GeometryReader { geo in
            let size = geo.size.width / 8
            VStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<8, id: \.self) { col in
                            let sq = Sq.index(file: col, rank: 7 - row)
                            ZStack {
                                Rectangle()
                                    .fill(Sq.isLight(sq) ? theme.lightSquare : theme.darkSquare)
                                if let piece = board[sq] {
                                    PieceGlyph(piece: piece, size: size)
                                }
                            }
                            .frame(width: size, height: size)
                        }
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// A 4×4 checkerboard tile showing a theme's square colors — the visual
/// half of the board-theme picker on the home screen (#117).
struct ThemeSwatchGrid: View {
    let theme: BoardTheme

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { col in
                        Rectangle()
                            .fill((row + col).isMultiple(of: 2) ? theme.lightSquare : theme.darkSquare)
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
