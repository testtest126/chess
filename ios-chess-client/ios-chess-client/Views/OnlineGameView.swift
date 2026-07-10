import SwiftUI
import SwiftData
import ChessKit
import ChessOnline

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
            .navigationTitle(session.timeControl.displayName)
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
                    Button("Offer Draw", systemImage: "equal.circle") {
                        session.offerDraw()
                    }
                    .disabled(session.phase != .playing || session.outgoingDrawOffer)
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
            .confirmationDialog(
                "\(session.opponentName) offers a draw",
                isPresented: Binding(
                    get: { session.incomingDrawOffer },
                    set: { if !$0 { session.respondToDrawOffer(accept: false) } }
                ),
                titleVisibility: .visible
            ) {
                Button("Accept Draw") { session.respondToDrawOffer(accept: true) }
                Button("Decline", role: .cancel) { session.respondToDrawOffer(accept: false) }
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
                switch phase {
                case .finished:
                    gameEnded()
                case .playing:
                    // A rematch started: hide the sheet, arm saving again.
                    showGameOver = false
                    saved = false
                default:
                    break
                }
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
            Label(session.timeControl.displayName, systemImage: "timer")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("You'll be matched with the next player who wants this time control.")
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
            VStack(alignment: .leading, spacing: 0) {
                Text(isOpponent ? session.opponentName : "You")
                    .font(.headline)
                if isOpponent, let rating = session.opponentRating {
                    Text("Elo \(rating)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if isOpponent && !session.opponentConnected {
                Label("reconnecting", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
            }
            Spacer()
            CapturedPiecesView(board: session.board, capturer: color)
            clockView(for: color)
        }
        .playerCardStyle()
        .padding(.horizontal)
    }

    /// Ticking clock; the active side counts down between server syncs.
    @ViewBuilder
    private func clockView(for color: PieceColor) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            if let seconds = session.remainingSeconds(for: color, at: context.date) {
                let isRunning = session.phase == .playing && session.board.sideToMove == color
                Text(Self.formatClock(seconds))
                    .font(.callout.monospacedDigit().weight(isRunning ? .bold : .regular))
                    .foregroundStyle(seconds < 30 && isRunning ? .red : (isRunning ? .primary : .secondary))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        isRunning ? Color.accentColor.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .accessibilityIdentifier("clock_\(color.rawValue)")
            }
        }
    }

    static func formatClock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
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

            if let delta = session.ratingDelta {
                Text("Rating \(delta >= 0 ? "+" : "")\(delta)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(delta > 0 ? .green : (delta < 0 ? .red : .secondary))
            }

            rematchButton

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
                // Walk away: closes the socket so the opponent's rematch
                // option flips to "opponent left".
                session.cancel()
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

    /// Rematch states: available → waiting for opponent → (game restarts),
    /// or unavailable once the opponent leaves.
    @ViewBuilder
    private var rematchButton: some View {
        if session.rematchUnavailable {
            Label("Opponent left", systemImage: "person.slash")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if session.rematchRequested {
            Label("Waiting for opponent…", systemImage: "hourglass")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Button {
                session.requestRematch()
            } label: {
                Label(
                    session.rematchOfferedByOpponent ? "Accept Rematch" : "Rematch",
                    systemImage: "arrow.2.squarepath"
                )
                .frame(maxWidth: .infinity)
            }
            .primaryActionButtonStyle()
            .overlay(alignment: .topTrailing) {
                if session.rematchOfferedByOpponent {
                    Circle().fill(.red).frame(width: 10, height: 10)
                        .offset(x: 4, y: -4)
                }
            }
        }
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
