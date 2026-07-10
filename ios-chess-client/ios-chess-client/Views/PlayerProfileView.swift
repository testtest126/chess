import SwiftUI
import ChessOnline

/// A player's public profile, opened from a leaderboard row: rating,
/// lifetime win/draw/loss record, and member-since date.
struct PlayerProfileView: View {
    /// Basics from the tapped leaderboard row, shown instantly while the
    /// full profile loads.
    let entry: LeaderboardEntry

    @Environment(\.dismiss) private var dismiss

    @State private var profile: PlayerProfileDTO?
    @State private var loadFailed = false

    private var isMe: Bool { entry.id == AccountStore.shared.userID }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 6) {
                        Image(systemName: isMe ? "person.crop.circle.fill" : "person.crop.circle")
                            .font(.system(size: 56))
                            .foregroundStyle(.tint)
                        Text(entry.displayName)
                            .font(.title2.bold())
                        Text("Elo \(profile?.rating ?? entry.rating)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if isMe {
                            Text("This is you")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                if let profile {
                    Section("Record") {
                        HStack(spacing: 0) {
                            recordColumn("Wins", count: profile.wins, color: .green)
                            recordColumn("Draws", count: profile.draws, color: .secondary)
                            recordColumn("Losses", count: profile.losses, color: .red)
                        }
                        .padding(.vertical, 4)

                        LabeledContent("Games played", value: "\(profile.games)")
                        LabeledContent(
                            "Member since",
                            value: profile.memberSince.formatted(date: .abbreviated, time: .omitted)
                        )
                    }
                } else if loadFailed {
                    Section {
                        Label("Couldn't load the full profile.", systemImage: "wifi.exclamationmark")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func recordColumn(_ label: String, count: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.title3.monospacedDigit().bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func load() async {
        loadFailed = false
        do {
            profile = try await AccountStore.shared.fetchProfile(of: entry.id)
        } catch {
            loadFailed = true
        }
    }
}

#Preview {
    PlayerProfileView(entry: LeaderboardEntry(
        id: UUID(), displayName: "Guest-1234", rating: 1216, games: 2
    ))
}
