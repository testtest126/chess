import SwiftUI
import Charts
import ChessKit
import ChessProtocol

/// Post-game analysis: accuracy summary, eval graph, and move-by-move playback.
/// Rebuilds the game from UCI moves so it works for both fresh and saved games.
struct ReviewView: View {
    let moves: [String]
    let playerColor: PieceColor
    let title: String

    @Environment(\.dismiss) private var dismiss

    @State private var game: Game?
    @State private var review: GameReview?
    @State private var analysisProgress = 0.0
    /// Index into `game.positions`: 0 is the initial position.
    @State private var ply = 0

    var body: some View {
        NavigationStack {
            Group {
                if let game, let review {
                    content(game: game, review: review)
                } else {
                    VStack(spacing: 12) {
                        ProgressView(value: analysisProgress) {
                            Text("Analyzing with engine…")
                        }
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 260)
                        Text("\(Int(analysisProgress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                let moves = self.moves
                let onProgress: @Sendable (Double) -> Void = { fraction in
                    Task { @MainActor in analysisProgress = fraction }
                }
                let (loadedGame, loadedReview) = await Task.detached(priority: .userInitiated) {
                    () -> (Game?, GameReview?) in
                    guard let game = try? Game.from(uciMoves: moves) else { return (nil, nil) }
                    // Engine-backed evaluation: bounded per position so even
                    // long games finish in seconds.
                    let engine = NegamaxEngine()
                    let limit = SearchLimit(depth: 3, maxNodes: 50_000, moveTime: 0.15)
                    let review = GameReview(
                        analyzing: game,
                        evaluator: { board in
                            let result = engine.search(board, limit: limit)
                            return board.sideToMove == .white
                                ? result.scoreCentipawns
                                : -result.scoreCentipawns
                        },
                        progress: onProgress
                    )
                    return (game, review)
                }.value
                self.game = loadedGame
                self.review = loadedReview
                self.ply = loadedGame?.moveCount ?? 0
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(game: Game, review: GameReview) -> some View {
        let positions = game.positions
        ScrollView {
            VStack(spacing: 16) {
                summaryCard(review.summary)

                evalChart(review)

                BoardView(
                    board: positions[ply],
                    orientation: playerColor,
                    lastMove: ply > 0 ? game.history[ply - 1].move : nil
                )
                .padding(.horizontal, 8)

                playbackControls(moveCount: game.moveCount)

                moveGrid(review: review)
            }
            .padding(.vertical)
        }
    }

    private func summaryCard(_ summary: GameReview.Summary) -> some View {
        HStack(spacing: 0) {
            accuracyColumn("White", accuracy: summary.accuracyWhite,
                           blunders: summary.blundersWhite,
                           mistakes: summary.mistakesWhite,
                           inaccuracies: summary.inaccuraciesWhite)
            Divider().frame(height: 60)
            accuracyColumn("Black", accuracy: summary.accuracyBlack,
                           blunders: summary.blundersBlack,
                           mistakes: summary.mistakesBlack,
                           inaccuracies: summary.inaccuraciesBlack)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private func accuracyColumn(_ name: String, accuracy: Double, blunders: Int, mistakes: Int, inaccuracies: Int) -> some View {
        VStack(spacing: 4) {
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(accuracy, format: .number.precision(.fractionLength(1)))%")
                .font(.title2.bold())
            Text("\(blunders)?? · \(mistakes)? · \(inaccuracies)?!")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Eval chart

    private func evalChart(_ review: GameReview) -> some View {
        Chart {
            ForEach(Array(review.evalTimeline.enumerated()), id: \.offset) { index, eval in
                let pawns = Double(min(max(eval, -800), 800)) / 100
                AreaMark(x: .value("Move", index), y: .value("Eval", pawns))
                    .foregroundStyle(.gray.opacity(0.25))
                LineMark(x: .value("Move", index), y: .value("Eval", pawns))
                    .foregroundStyle(.gray)
            }
            RuleMark(y: .value("Even", 0))
                .foregroundStyle(.secondary.opacity(0.4))
            RuleMark(x: .value("Current", ply))
                .foregroundStyle(.blue.opacity(0.6))
        }
        .chartYScale(domain: -8...8)
        .chartYAxis {
            AxisMarks(values: [-8, -4, 0, 4, 8])
        }
        .frame(height: 120)
        .padding(.horizontal)
    }

    // MARK: - Playback

    private func playbackControls(moveCount: Int) -> some View {
        HStack(spacing: 24) {
            Button { ply = 0 } label: { Image(systemName: "backward.end.fill") }
                .disabled(ply == 0)
            Button { ply = max(0, ply - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(ply == 0)
            Text("\(ply) / \(moveCount)")
                .font(.callout.monospacedDigit())
                .frame(minWidth: 70)
            Button { ply = min(moveCount, ply + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(ply == moveCount)
            Button { ply = moveCount } label: { Image(systemName: "forward.end.fill") }
                .disabled(ply == moveCount)
        }
        .font(.title3)
        .buttonStyle(.plain)
    }

    private func moveGrid(review: GameReview) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
            ForEach(review.moves) { analysis in
                Button {
                    ply = analysis.plyIndex + 1
                } label: {
                    HStack(spacing: 4) {
                        if analysis.plyIndex % 2 == 0 {
                            Text("\(analysis.plyIndex / 2 + 1).")
                                .foregroundStyle(.secondary)
                        }
                        Text(analysis.san)
                            .fontWeight(.medium)
                        Circle()
                            .fill(judgmentColor(analysis.judgment))
                            .frame(width: 7, height: 7)
                    }
                    .font(.callout.monospaced())
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        ply == analysis.plyIndex + 1 ? Color.blue.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }

    private func judgmentColor(_ judgment: GameReview.Judgment) -> Color {
        switch judgment {
        case .best: return .green
        case .good: return .teal
        case .inaccuracy: return .yellow
        case .mistake: return .orange
        case .blunder: return .red
        }
    }
}

#Preview {
    ReviewView(
        moves: ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "g8f6", "f3g5", "f6e4", "g5f7"],
        playerColor: .white,
        title: "Game Review"
    )
}
