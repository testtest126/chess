import SwiftUI
import ChessKit

/// Non-interactive 8×8 miniature of a position, used for history-row
/// thumbnails (#117). `BoardView` is deliberately not reused here: its
/// gestures, move hints, and per-square accessibility do real work that a
/// 56pt decoration must skip entirely.
struct MiniBoard: View {
    let board: Board
    let theme: BoardTheme
    /// Bottom-of-board perspective; history rows pass the side the player
    /// held so the miniature matches the ReviewView the row opens.
    var orientation: PieceColor = .white

    var body: some View {
        GeometryReader { geo in
            let size = geo.size.width / 8
            VStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<8, id: \.self) { col in
                            let rank = orientation == .white ? 7 - row : row
                            let file = orientation == .white ? col : 7 - col
                            let sq = Sq.index(file: file, rank: rank)
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
