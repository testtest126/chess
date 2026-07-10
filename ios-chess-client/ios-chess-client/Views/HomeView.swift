import SwiftUI
import SwiftData
import ChessKit

/// Root screen: start a new game against the engine, or revisit past games.
struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedGame.date, order: .reverse) private var savedGames: [SavedGame]

    @State private var colorChoice: ColorChoice = .white
    @State private var difficulty: Difficulty = .casual
    @State private var activeSession: GameSession?
    @State private var onlineSession: OnlineGameSession?
    @State private var reviewTarget: SavedGame?

    enum ColorChoice: String, CaseIterable, Identifiable {
        case white, black, random
        var id: String { rawValue }
        var label: String { rawValue.capitalized }

        var resolved: PieceColor {
            switch self {
            case .white: return .white
            case .black: return .black
            case .random: return Bool.random() ? .white : .black
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Play Online") {
                    Button {
                        onlineSession = OnlineGameSession()
                    } label: {
                        Label("Play Online", systemImage: "globe")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.semibold)
                    }
                    .primaryActionButtonStyle()
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)

                    if let name = AccountStore.shared.displayName {
                        let rating = AccountStore.shared.rating.map { " · Elo \($0)" } ?? ""
                        Text("Playing as \(name)\(rating)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                    }
                }

                Section("Play the Engine") {
                    Picker("Play as", selection: $colorChoice) {
                        ForEach(ColorChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Engine strength", selection: $difficulty) {
                        ForEach(Difficulty.allCases) { level in
                            Text(level.label).tag(level)
                        }
                    }

                    Button {
                        activeSession = GameSession(
                            playerColor: colorChoice.resolved,
                            difficulty: difficulty
                        )
                    } label: {
                        Label("Start Game", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.semibold)
                    }
                    .primaryActionButtonStyle()
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                }

                Section("Past Games") {
                    if savedGames.isEmpty {
                        Text("Finished games show up here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(savedGames) { saved in
                        Button {
                            reviewTarget = saved
                        } label: {
                            SavedGameRow(saved: saved)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            modelContext.delete(savedGames[index])
                        }
                    }
                }
            }
            .navigationTitle("MateMate")
        }
        .fullScreenCover(item: $activeSession) { session in
            GameView(session: session)
        }
        .fullScreenCover(item: $onlineSession) { session in
            OnlineGameView(session: session)
        }
        .sheet(item: $reviewTarget) { saved in
            ReviewView(
                moves: saved.moves,
                playerColor: saved.playerColor,
                title: saved.date.formatted(date: .abbreviated, time: .omitted)
            )
        }
    }
}

struct SavedGameRow: View {
    let saved: SavedGame

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(saved.playerOutcome) \(saved.endReasonDescription)")
                    .font(.headline)
                Text("As \(saved.playerColor.rawValue.capitalized) vs \(saved.opponentDescription) · \((saved.moveCount + 1) / 2) moves")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(saved.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    HomeView()
        .modelContainer(for: SavedGame.self, inMemory: true)
}
