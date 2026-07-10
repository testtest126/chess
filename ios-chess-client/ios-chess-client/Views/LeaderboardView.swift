import SwiftUI
import ChessOnline

/// Top online players by Elo. The caller's own row is highlighted.
struct LeaderboardView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [LeaderboardEntry]?
    @State private var loadFailed = false

    var body: some View {
        NavigationStack {
            Group {
                if let entries {
                    if entries.isEmpty {
                        ContentUnavailableView(
                            "No Ranked Players Yet",
                            systemImage: "trophy",
                            description: Text("Finish an online game to appear here.")
                        )
                    } else {
                        rankingList(entries)
                    }
                } else if loadFailed {
                    ContentUnavailableView(
                        "Couldn't Load Leaderboard",
                        systemImage: "wifi.exclamationmark",
                        description: Text("Check that you're online and try again.")
                    )
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Leaderboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func rankingList(_ entries: [LeaderboardEntry]) -> some View {
        List {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                let isMe = entry.id == AccountStore.shared.userID
                HStack(spacing: 12) {
                    rankBadge(index + 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.displayName)
                            .font(.headline)
                        Text("^[\(entry.games) game](inflect: true)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(entry.rating)")
                        .font(.title3.monospacedDigit().bold())
                }
                .listRowBackground(isMe ? Color.accentColor.opacity(0.12) : nil)
            }
        }
    }

    @ViewBuilder
    private func rankBadge(_ rank: Int) -> some View {
        if rank <= 3 {
            Image(systemName: "medal.fill")
                .foregroundStyle(rank == 1 ? .yellow : (rank == 2 ? .gray : .brown))
                .frame(width: 32)
        } else {
            Text("\(rank)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32)
        }
    }

    private func load() async {
        loadFailed = false
        do {
            entries = try await AccountStore.shared.fetchLeaderboard()
        } catch {
            if entries == nil { loadFailed = true }
        }
    }
}

#Preview {
    LeaderboardView()
}
