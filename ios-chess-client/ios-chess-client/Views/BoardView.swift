import SwiftUI
import ChessKit

/// Renders a position and, when `onMove` is set, handles tap-to-move input
/// with legal-move hints and a promotion picker.
struct BoardView: View {
    let board: Board
    var orientation: PieceColor = .white
    var lastMove: Move?
    /// Engine suggestion to spotlight (from/to squares).
    var hintMove: Move?
    /// Non-nil enables interaction; called with a fully-formed legal move.
    var onMove: ((Move) -> Void)?

    @State private var selectedSquare: Int?
    @State private var promotionMoves: [Move] = []

    private var legalTargets: Set<Int> {
        guard let selected = selectedSquare else { return [] }
        return Set(board.legalMoves(from: selected).map(\.to))
    }

    private var checkedKingSquare: Int? {
        guard board.isInCheck(board.sideToMove) else { return nil }
        return board.kingSquare(of: board.sideToMove)
    }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height) / 8
            VStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<8, id: \.self) { col in
                            squareView(square(row: row, col: col), size: size, row: row, col: col)
                        }
                    }
                }
            }
            .frame(width: size * 8, height: size * 8)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .confirmationDialog("Promote to", isPresented: promotionDialogShown, titleVisibility: .visible) {
            ForEach(promotionMoves, id: \.self) { move in
                Button(move.promotion.map(promotionLabel) ?? "") {
                    play(move)
                }
            }
        }
        .onChange(of: board) {
            selectedSquare = nil
        }
    }

    // MARK: - Squares

    private func square(row: Int, col: Int) -> Int {
        let rank = orientation == .white ? 7 - row : row
        let file = orientation == .white ? col : 7 - col
        return Sq.index(file: file, rank: rank)
    }

    @ViewBuilder
    private func squareView(_ sq: Int, size: CGFloat, row: Int, col: Int) -> some View {
        let piece = board[sq]
        let isLight = Sq.isLight(sq)

        ZStack {
            Rectangle()
                .fill(isLight ? Self.lightColor : Self.darkColor)

            if let last = lastMove, sq == last.from || sq == last.to {
                Rectangle().fill(Self.lastMoveTint)
            }
            if let hint = hintMove, sq == hint.from || sq == hint.to {
                Rectangle().fill(Self.hintMoveTint)
            }
            if sq == selectedSquare {
                Rectangle().fill(Self.selectionTint)
            }
            if sq == checkedKingSquare {
                Circle()
                    .fill(RadialGradient(
                        colors: [.red.opacity(0.75), .red.opacity(0)],
                        center: .center, startRadius: size * 0.1, endRadius: size * 0.55
                    ))
            }

            coordinateLabels(sq: sq, size: size, row: row, col: col, isLight: isLight)

            if let piece {
                PieceGlyph(piece: piece, size: size)
            }

            if legalTargets.contains(sq) {
                if piece != nil || sq == board.enPassantSquare {
                    Circle()
                        .strokeBorder(Self.hintColor, lineWidth: size * 0.09)
                        .padding(size * 0.04)
                } else {
                    Circle()
                        .fill(Self.hintColor)
                        .frame(width: size * 0.3, height: size * 0.3)
                }
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onTapGesture { tapped(sq) }
        .accessibilityElement()
        .accessibilityIdentifier("square_\(Sq.name(sq))")
        .accessibilityLabel(accessibilityDescription(sq))
    }

    @ViewBuilder
    private func coordinateLabels(sq: Int, size: CGFloat, row: Int, col: Int, isLight: Bool) -> some View {
        let labelColor = isLight ? Self.darkColor : Self.lightColor
        if col == 0 {
            Text("\(Sq.rank(sq) + 1)")
                .font(.system(size: size * 0.22, weight: .semibold))
                .foregroundStyle(labelColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(size * 0.06)
        }
        if row == 7 {
            Text(String("abcdefgh"[String.Index(utf16Offset: Sq.file(sq), in: "abcdefgh")]))
                .font(.system(size: size * 0.22, weight: .semibold))
                .foregroundStyle(labelColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(size * 0.06)
        }
    }

    private func accessibilityDescription(_ sq: Int) -> String {
        guard let piece = board[sq] else { return Sq.name(sq) }
        return "\(Sq.name(sq)), \(piece.color.rawValue) \(piece.kind.rawValue)"
    }

    // MARK: - Interaction

    private func tapped(_ sq: Int) {
        guard onMove != nil else { return }

        if let selected = selectedSquare {
            let candidates = board.legalMoves(from: selected).filter { $0.to == sq }
            if !candidates.isEmpty {
                if candidates.count > 1 {
                    // Same from/to with multiple options means promotion.
                    promotionMoves = candidates.sorted { promotionOrder($0) < promotionOrder($1) }
                } else {
                    play(candidates[0])
                }
                return
            }
        }

        // Select (or reselect) one of the side-to-move's pieces.
        if let piece = board[sq], piece.color == board.sideToMove, sq != selectedSquare {
            selectedSquare = sq
        } else {
            selectedSquare = nil
        }
    }

    private func play(_ move: Move) {
        selectedSquare = nil
        promotionMoves = []
        onMove?(move)
    }

    private var promotionDialogShown: Binding<Bool> {
        Binding(
            get: { !promotionMoves.isEmpty },
            set: { if !$0 { promotionMoves = [] } }
        )
    }

    private func promotionLabel(_ kind: PieceKind) -> String {
        switch kind {
        case .queen: return "Queen"
        case .rook: return "Rook"
        case .bishop: return "Bishop"
        case .knight: return "Knight"
        default: return kind.rawValue.capitalized
        }
    }

    private func promotionOrder(_ move: Move) -> Int {
        switch move.promotion {
        case .queen: return 0
        case .rook: return 1
        case .bishop: return 2
        case .knight: return 3
        default: return 4
        }
    }

    // MARK: - Palette

    static let lightColor = Color(red: 0.94, green: 0.85, blue: 0.71)
    static let darkColor = Color(red: 0.71, green: 0.53, blue: 0.39)
    static let selectionTint = Color.yellow.opacity(0.45)
    static let lastMoveTint = Color.yellow.opacity(0.30)
    static let hintMoveTint = Color.blue.opacity(0.35)
    static let hintColor = Color.black.opacity(0.22)
}

/// A single piece drawn with Unicode figurines. The filled (black) glyph is
/// used for both colors and tinted, since outline glyphs render inconsistently.
struct PieceGlyph: View {
    let piece: Piece
    let size: CGFloat

    var body: some View {
        Text(glyph)
            .font(.system(size: size * 0.78))
            .foregroundStyle(piece.color == .white ? Self.whiteTint : Self.blackTint)
            .shadow(
                color: piece.color == .white ? .black.opacity(0.5) : .black.opacity(0.25),
                radius: size * 0.025, x: 0, y: size * 0.02
            )
            .minimumScaleFactor(0.5)
    }

    private static let whiteTint = Color(white: 0.99)
    private static let blackTint = Color(white: 0.13)

    /// U+FE0E (variation selector 15) forces text presentation. Without it,
    /// the pawn glyph U+265F — uniquely among chess figurines — defaults to
    /// its emoji form, which ignores `foregroundStyle` and always looks black.
    private var glyph: String {
        switch piece.kind {
        case .king: return "\u{265A}\u{FE0E}"
        case .queen: return "\u{265B}\u{FE0E}"
        case .rook: return "\u{265C}\u{FE0E}"
        case .bishop: return "\u{265D}\u{FE0E}"
        case .knight: return "\u{265E}\u{FE0E}"
        case .pawn: return "\u{265F}\u{FE0E}"
        }
    }
}

#Preview {
    BoardView(board: Board(), onMove: { _ in })
        .padding()
}
