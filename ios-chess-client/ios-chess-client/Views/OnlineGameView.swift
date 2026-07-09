import SwiftUI
import SwiftData
import ChessKit

/// The online match screen: matchmaking spinner, then the live board.
struct OnlineGameView: View {
    let session: OnlineGameSession

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var flipped = false
    @State private var showResignConfirmation = false
    @State private var showGameOver = false
    @State private var showReview = false
    @State private var saved = false

    private var bottomColor: PieceColor {
        flipped ? session.playerColor.opposite : session.playerColor
    }

    var body: some View {
        NavigationStack {
            Group {
                switch session.phase {
                case .connecting, .queued:
                    matchmakingView
                case .playing, .finished:
                    boardView
                case .failed(let message):
                    failureView(message)
                }
            }
            .navigationTitle("Online")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") {
                        if session.phase == .playing {
                            showResignConfirmation = true
                        } else {
                            session.cancel()
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
                    .disabled(session.phase != .playing)
                }
            }
            .confirmationDialog(
                "Resign this game?", isPresented: $showResignConfirmation, titleVisibility: .visible
            ) {
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
            .onChange(of: session.phase) { _, phase in
                if case .finished = phase { gameEnded() }
            }
        }
        .interactiveDismissDisabled()
    }

    // MARK: - Phases

    private var matchmakingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(session.phase == .queued ? "Finding an opponent…" : "Connecting…")
                .font(.headline)
            Text("You'll be matched with the next player in line.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Cancel") {
                session.cancel()
                dismiss()
            }
            .secondaryActionButtonStyle()
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var boardView: some View {
        VStack(spacing: 12) {
            playerBar(for: bottomColor.opposite)

            BoardView(
                board: session.board,
                orientation: bottomColor,
                lastMove: session.lastMove,
                onMove: { session.playMove($0) }
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
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
            Button("Close") { dismiss() }
                .primaryActionButtonStyle()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func playerBar(for color: PieceColor) -> some View {
        let isOpponent = color != session.playerColor
        HStack(spacing: 8) {
            Image(systemName: isOpponent ? "person.crop.circle" : "person.fill")
                .foregroundStyle(.secondary)
            Text(isOpponent ? session.opponentName : "You")
                .font(.headline)
            if isOpponent && !session.opponentConnected {
                Label("reconnecting", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
            }
            Spacer()
            CapturedPiecesView(board: session.board, capturer: color)
        }
        .playerCardStyle()
        .padding(.horizontal)
    }

    // MARK: - Game over

    private func gameEnded() {
        guard case .finished(let result, let reason) = session.phase else { return }
        if !saved, session.game.moveCount > 0 {
            saved = true
            modelContext.insert(SavedGame(
                date: Date(),
                playerColor: session.playerColor,
                difficulty: nil,
                result: result,
                endReason: reason,
                uciMoves: session.game.uciMoves,
                opponentName: session.opponentName
            ))
        }
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
        guard case .finished(let result, _) = session.phase else { return "" }
        switch result {
        case .draw: return "Draw"
        case .whiteWins: return session.playerColor == .white ? "You Won! 🎉" : "You Lost"
        case .blackWins: return session.playerColor == .black ? "You Won! 🎉" : "You Lost"
        case .ongoing: return ""
        }
    }

    private var resultDetail: String {
        guard case .finished(_, let reason) = session.phase else { return "" }
        switch reason {
        case .checkmate: return "Checkmate"
        case .stalemate: return "Stalemate"
        case .resignation: return "By resignation"
        case .fiftyMoveRule: return "Draw by the 50-move rule"
        case .threefoldRepetition: return "Draw by threefold repetition"
        case .insufficientMaterial: return "Draw by insufficient material"
        case .drawAgreement: return "Draw by agreement"
        case .timeout: return "On time"
        case .abandoned: return "Opponent abandoned the game"
        case nil: return ""
        }
    }
}

#Preview {
    OnlineGameView(session: OnlineGameSession())
        .modelContainer(for: SavedGame.self, inMemory: true)
}
