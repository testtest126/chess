import SwiftUI
import SwiftData
import ChessKit

/// The live game screen: board, player bars, move list, and game-over flow.
struct GameView: View {
    let session: GameSession

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var flipped = false
    @State private var showResignConfirmation = false
    @State private var showGameOver = false
    @State private var showReview = false
    @State private var savedGame: SavedGame?

    private var bottomColor: PieceColor {
        flipped ? session.playerColor.opposite : session.playerColor
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                playerBar(for: bottomColor.opposite)

                BoardView(
                    board: session.board,
                    orientation: bottomColor,
                    lastMove: session.lastMove,
                    hintMove: session.hintMove,
                    onMove: { session.playPlayerMove($0) }
                )
                .padding(.horizontal, 8)

                playerBar(for: bottomColor)

                MoveListView(history: session.game.history)
                    .frame(height: 44)

                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .background(Color(.systemGroupedBackground))
            .sensoryFeedback(.impact(weight: .light), trigger: session.game.moveCount)
            .sensoryFeedback(.success, trigger: session.game.isOver) { _, isOver in isOver }
            .navigationTitle("MateMate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") {
                        if !session.game.isOver, session.game.moveCount > 0 {
                            showResignConfirmation = true
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Flip", systemImage: "arrow.up.arrow.down") {
                        withAnimation { flipped.toggle() }
                    }
                    Button("Resign", systemImage: "flag.fill") {
                        showResignConfirmation = true
                    }
                    .disabled(session.game.isOver)
                }
            }
            .confirmationDialog("Resign this game?", isPresented: $showResignConfirmation, titleVisibility: .visible) {
                Button("Resign", role: .destructive) { session.resign() }
            }
            .sheet(isPresented: $showGameOver) {
                gameOverSheet
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $showReview) {
                ReviewView(
                    moves: session.game.uciMoves,
                    playerColor: session.playerColor,
                    title: "Game Review"
                )
            }
            .onAppear { session.start() }
            .onChange(of: session.game.isOver) { _, isOver in
                if isOver { gameEnded() }
            }
        }
        .interactiveDismissDisabled()
    }

    // MARK: - Player bars

    @ViewBuilder
    private func playerBar(for color: PieceColor) -> some View {
        let isEngine = color != session.playerColor
        HStack(spacing: 8) {
            Image(systemName: isEngine ? "desktopcomputer" : "person.fill")
                .foregroundStyle(.secondary)
            Text(isEngine ? "Engine (\(session.difficulty.label))" : "You")
                .font(.headline)
            if isEngine && session.isEngineThinking {
                ProgressView()
                    .controlSize(.small)
            }
            if !isEngine {
                // 44pt frames: the bare glyphs hit-test at ~15-21pt, well
                // under the accessibility minimum (audit #83, finding P1.3).
                Button {
                    session.requestHint()
                } label: {
                    Label("Hint", systemImage: session.isFindingHint ? "lightbulb.fill" : "lightbulb")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!session.isPlayerTurn || session.isFindingHint)
                Button {
                    session.takeBack()
                } label: {
                    Label("Take Back", systemImage: "arrow.uturn.backward")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!session.canTakeBack)
            }
            Spacer()
            CapturedPiecesView(board: session.board, capturer: color)
        }
        .playerCardStyle()
        .padding(.horizontal)
    }

    // MARK: - Game over

    private func gameEnded() {
        let record = SavedGame(
            date: Date(),
            playerColor: session.playerColor,
            difficulty: session.difficulty,
            result: session.game.result,
            endReason: session.game.endReason,
            uciMoves: session.game.uciMoves
        )
        modelContext.insert(record)
        savedGame = record
        showGameOver = true
    }

    private var gameOverSheet: some View {
        VStack(spacing: 16) {
            Text(resultHeadline)
                .font(.largeTitle.bold())
            Text(resultDetail)
                .foregroundStyle(.secondary)

            if session.game.moveCount > 0 {
                Button {
                    showGameOver = false
                    showReview = true
                } label: {
                    Label("Review Game", systemImage: "chart.line.uptrend.xyaxis")
                        .frame(maxWidth: .infinity)
                }
                .primaryActionButtonStyle()
            }

            Button {
                showGameOver = false
                dismiss()
            } label: {
                Text("Done")
                    .frame(maxWidth: .infinity)
            }
            .secondaryActionButtonStyle()
        }
        .padding(24)
        .presentationCornerRadius(28)
        .presentationDragIndicator(.visible)
    }

    private var resultHeadline: String {
        switch session.game.result {
        case .draw: return String(localized: "Draw", comment: "Draw game result")
        case .whiteWins:
            return session.playerColor == .white
                ? String(localized: "You Won! 🎉", comment: "Game-over headline")
                : String(localized: "You Lost", comment: "Game-over headline")
        case .blackWins:
            return session.playerColor == .black
                ? String(localized: "You Won! 🎉", comment: "Game-over headline")
                : String(localized: "You Lost", comment: "Game-over headline")
        case .ongoing: return ""
        }
    }

    private var resultDetail: String {
        switch session.game.endReason {
        case .checkmate: return String(localized: "Checkmate", comment: "Reason the game ended")
        case .stalemate: return String(localized: "Stalemate", comment: "Reason the game ended")
        case .resignation: return String(localized: "By resignation", comment: "Reason the game ended")
        case .fiftyMoveRule: return String(localized: "Draw by the 50-move rule", comment: "Reason the game ended")
        case .threefoldRepetition: return String(localized: "Draw by threefold repetition", comment: "Reason the game ended")
        case .insufficientMaterial: return String(localized: "Draw by insufficient material", comment: "Reason the game ended")
        case .drawAgreement: return String(localized: "Draw by agreement", comment: "Reason the game ended")
        case .timeout: return String(localized: "On time", comment: "Reason the game ended (ran out of clock)")
        case .abandoned, nil: return ""
        }
    }
}

/// Opponent pieces missing from the board relative to the starting set,
/// shown next to the capturing side with the material difference.
struct CapturedPiecesView: View {
    let board: Board
    let capturer: PieceColor

    private static let startingCounts: [PieceKind: Int] = [
        .pawn: 8, .knight: 2, .bishop: 2, .rook: 2, .queen: 1,
    ]

    var body: some View {
        let captured = capturedKinds()
        HStack(spacing: -2) {
            ForEach(Array(captured.enumerated()), id: \.offset) { _, kind in
                PieceGlyph(piece: Piece(color: capturer.opposite, kind: kind), size: 18)
            }
            if materialLead > 0 {
                Text("+\(materialLead)")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
            }
        }
    }

    private func capturedKinds() -> [PieceKind] {
        let victim = capturer.opposite
        var counts: [PieceKind: Int] = [:]
        for case let piece? in board.squares where piece.color == victim {
            counts[piece.kind, default: 0] += 1
        }
        var result: [PieceKind] = []
        for kind in [PieceKind.pawn, .knight, .bishop, .rook, .queen] {
            let missing = (Self.startingCounts[kind] ?? 0) - (counts[kind] ?? 0)
            result.append(contentsOf: Array(repeating: kind, count: max(0, missing)))
        }
        return result
    }

    private var materialLead: Int {
        var lead = 0
        for case let piece? in board.squares {
            let value = piece.kind.centipawnValue / 100
            lead += piece.color == capturer ? value : -value
        }
        return lead
    }
}

/// Horizontal scrolling SAN move list that follows the latest move.
struct MoveListView: View {
    let history: [Game.HistoryEntry]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(history.enumerated()), id: \.offset) { index, entry in
                        HStack(spacing: 3) {
                            if index % 2 == 0 {
                                Text("\(index / 2 + 1).")
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.san)
                                .fontWeight(.medium)
                        }
                        .font(.callout.monospaced())
                        .id(index)
                    }
                }
                .padding(.horizontal)
            }
            .onChange(of: history.count) {
                if let last = history.indices.last {
                    withAnimation { proxy.scrollTo(last, anchor: .trailing) }
                }
            }
        }
    }
}

#Preview {
    GameView(session: GameSession(playerColor: .white, difficulty: .casual))
        .modelContainer(for: SavedGame.self, inMemory: true)
}
