import SwiftUI
import ChessKit

/// Renders a position and, when `onMove` is set, handles tap-to-move and
/// drag-to-move input with legal-move hints and a promotion picker.
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
    @AppStorage(BoardTheme.storageKey) private var themeRaw = BoardTheme.classic.rawValue

    private var theme: BoardTheme { BoardTheme(rawValue: themeRaw) ?? .classic }

    // Drag-to-move state.
    @State private var draggedFrom: Int?
    @State private var draggedOver: Int?
    @State private var dragLocation: CGPoint = .zero

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
            .overlay {
                // The dragged piece floats above the grid, under the finger.
                if let from = draggedFrom, let piece = board[from] {
                    PieceGlyph(piece: piece, size: size * 1.4)
                        .position(dragLocation)
                        .allowsHitTesting(false)
                }
            }
            .gesture(interactionGesture(squareSize: size), including: onMove != nil ? .all : .subviews)
            .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .confirmationDialog("Promote to", isPresented: promotionDialogShown, titleVisibility: .visible) {
            ForEach(promotionMoves, id: \.self) { move in
                Button(move.promotion?.localizedName ?? "") {
                    play(move)
                }
            }
        }
        .onChange(of: board) {
            selectedSquare = nil
            draggedFrom = nil
        }
    }

    // MARK: - Squares

    private func square(row: Int, col: Int) -> Int {
        let rank = orientation == .white ? 7 - row : row
        let file = orientation == .white ? col : 7 - col
        return Sq.index(file: file, rank: rank)
    }

    /// The square under a point in the board's own coordinate space.
    private func square(at point: CGPoint, squareSize: CGFloat) -> Int? {
        let col = Int(point.x / squareSize)
        let row = Int(point.y / squareSize)
        guard (0...7).contains(col), (0...7).contains(row) else { return nil }
        return square(row: row, col: col)
    }

    // MARK: - Gesture

    /// One gesture serves both input styles: a press that never leaves its
    /// starting square is a tap (select / move to target); dragging a piece
    /// lifts it under the finger and drops it on the release square.
    private func interactionGesture(squareSize: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard onMove != nil else { return }
                dragLocation = value.location

                if draggedFrom == nil {
                    guard let start = square(at: value.startLocation, squareSize: squareSize),
                          let piece = board[start], piece.color == board.sideToMove
                    else { return }
                    // Only treat it as a lift once the finger clearly moves.
                    let dx = value.translation.width, dy = value.translation.height
                    guard dx * dx + dy * dy > 25 else { return }
                    draggedFrom = start
                    selectedSquare = start
                }
                draggedOver = square(at: value.location, squareSize: squareSize)
            }
            .onEnded { value in
                guard onMove != nil else { return }
                defer {
                    draggedFrom = nil
                    draggedOver = nil
                }

                if let from = draggedFrom {
                    // Drop: play if the release square is a legal target.
                    guard let target = square(at: value.location, squareSize: squareSize),
                          target != from
                    else { return }
                    attemptMove(from: from, to: target)
                } else if let tappedSquare = square(at: value.location, squareSize: squareSize) {
                    tapped(tappedSquare)
                }
            }
    }

    @ViewBuilder
    private func squareView(_ sq: Int, size: CGFloat, row: Int, col: Int) -> some View {
        let piece = board[sq]
        let isLight = Sq.isLight(sq)

        ZStack {
            Rectangle()
                .fill(isLight ? theme.lightSquare : theme.darkSquare)

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

            if let piece, sq != draggedFrom {
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

            if draggedFrom != nil, sq == draggedOver {
                Rectangle()
                    .strokeBorder(.white.opacity(0.85), lineWidth: size * 0.06)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityIdentifier("square_\(Sq.name(sq))")
        .accessibilityLabel(accessibilityDescription(sq))
        .accessibilityValue(Self.accessibilityValue(
            square: sq,
            selected: selectedSquare,
            legalTargets: legalTargets,
            lastMove: lastMove,
            hintMove: hintMove,
            checkedKing: checkedKingSquare
        ))
        .accessibilityAddTraits(squareTraits(sq))
    }

    /// Squares act as buttons on interactive boards; the picked-up square
    /// reads as selected.
    private func squareTraits(_ sq: Int) -> AccessibilityTraits {
        guard onMove != nil else { return [] }
        return selectedSquare == sq ? [.isButton, .isSelected] : .isButton
    }

    /// VoiceOver state for a square — everything the highlights show visually:
    /// "selected", "possible move", "last move", "hint", "in check". Empty for
    /// a plain square. Static and state-injected so tests can cover the matrix.
    static func accessibilityValue(
        square: Int,
        selected: Int?,
        legalTargets: Set<Int>,
        lastMove: Move?,
        hintMove: Move?,
        checkedKing: Int?
    ) -> String {
        var parts: [String] = []
        if selected == square {
            parts.append(String(localized: "selected", comment: "VoiceOver square state"))
        }
        if legalTargets.contains(square) {
            parts.append(String(localized: "possible move", comment: "VoiceOver square state"))
        }
        if lastMove?.from == square || lastMove?.to == square {
            parts.append(String(localized: "last move", comment: "VoiceOver square state"))
        }
        if hintMove?.from == square || hintMove?.to == square {
            parts.append(String(localized: "hint", comment: "VoiceOver square state"))
        }
        if checkedKing == square {
            parts.append(String(localized: "in check", comment: "VoiceOver square state"))
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func coordinateLabels(sq: Int, size: CGFloat, row: Int, col: Int, isLight: Bool) -> some View {
        let labelColor = isLight ? theme.darkSquare : theme.lightSquare
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
        return String(localized: "\(Sq.name(sq)), \(piece.color.localizedName) \(piece.kind.localizedName)",
                      comment: "VoiceOver label for an occupied square: square name, piece color, piece kind")
    }

    // MARK: - Interaction

    private func tapped(_ sq: Int) {
        guard onMove != nil else { return }

        if let selected = selectedSquare, attemptMove(from: selected, to: sq) {
            return
        }

        // Select (or reselect) one of the side-to-move's pieces.
        if let piece = board[sq], piece.color == board.sideToMove, sq != selectedSquare {
            selectedSquare = sq
        } else {
            selectedSquare = nil
        }
    }

    /// Plays from→to if legal (or raises the promotion picker when several
    /// promotions match). Returns whether the pair matched any legal move.
    @discardableResult
    private func attemptMove(from: Int, to: Int) -> Bool {
        let candidates = board.legalMoves(from: from).filter { $0.to == to }
        guard !candidates.isEmpty else { return false }
        if candidates.count > 1 {
            // Same from/to with multiple options means promotion.
            promotionMoves = candidates.sorted { promotionOrder($0) < promotionOrder($1) }
        } else {
            play(candidates[0])
        }
        return true
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

    private func promotionOrder(_ move: Move) -> Int {
        switch move.promotion {
        case .queen: return 0
        case .rook: return 1
        case .bishop: return 2
        case .knight: return 3
        default: return 4
        }
    }

    // MARK: - Palette (square colors live in BoardTheme)

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
