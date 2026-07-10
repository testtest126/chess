import SwiftUI
import SwiftData
import ChessKit
import ChessOnline
import AuthenticationServices

/// Root screen: start a new game against the engine, or revisit past games.
struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedGame.date, order: .reverse) private var savedGames: [SavedGame]

    @State private var colorChoice: ColorChoice = .white
    @AppStorage(Difficulty.storageKey) private var difficultyRaw = Difficulty.casual.rawValue
    @AppStorage(TimeControl.storageKey) private var timeControlRaw = TimeControl.default.rawValue
    @State private var activeSession: GameSession?
    @State private var onlineSession: OnlineGameSession?
    @State private var reviewTarget: SavedGame?
    @State private var showLeaderboard = false
    @State private var showRenameDialog = false
    @State private var nameInput = ""
    @State private var renameError: String?
    @State private var signInError: String?
    @State private var isSigningInWithApple = false
    @AppStorage(BoardTheme.storageKey) private var boardThemeRaw = BoardTheme.classic.rawValue

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
                if let opponent = ActiveGameStore.shared.opponentName {
                    Section {
                        Button {
                            onlineSession = OnlineGameSession()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "gamecontroller.fill")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Game in progress")
                                        .fontWeight(.semibold)
                                    Text("Tap to resume vs \(opponent)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("Play Online") {
                    // Bare speed names: three notated segments ("Blitz 5+3")
                    // truncate on narrow phones. The notation shows up on the
                    // matchmaking screen and the in-game title instead.
                    Picker("Time control", selection: $timeControlRaw) {
                        ForEach(TimeControl.allCases, id: \.rawValue) { control in
                            Text(control.label).tag(control.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    // Guest-first: online play never requires signing in.
                    Button {
                        onlineSession = OnlineGameSession(
                            timeControl: TimeControl(rawValue: timeControlRaw) ?? .default
                        )
                    } label: {
                        Label("Play Online", systemImage: "globe")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.semibold)
                    }
                    .primaryActionButtonStyle()
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .disabled(isSigningInWithApple)

                    if let name = AccountStore.shared.displayName {
                        let rating = AccountStore.shared.rating.map { " · Elo \($0)" } ?? ""
                        Button {
                            nameInput = name
                            showRenameDialog = true
                        } label: {
                            HStack(spacing: 4) {
                                Text("Playing as \(name)\(rating)")
                                Image(systemName: "pencil")
                                    .font(.caption2)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                    }

                    // Optional: link (guests keep rating/history) or recover
                    // an account from another device. Hidden once linked.
                    if AccountStore.shared.appleLinked {
                        Label("Account recoverable with Apple", systemImage: "checkmark.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                    } else {
                        SignInWithAppleButton { request in
                            request.requestedScopes = [.fullName]
                        } onCompletion: { result in
                            handleAppleSignInResult(result)
                        }
                        .frame(height: 40)
                        .disabled(isSigningInWithApple)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 2, trailing: 16))
                        .listRowBackground(Color.clear)

                        if isSigningInWithApple {
                            HStack(spacing: 12) {
                                ProgressView()
                                    .scaleEffect(0.9)
                                Text("Signing in…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                        } else {
                            Text(AccountStore.shared.displayName == nil
                                 ? "Recovers your account if you've played before."
                                 : "Keeps your rating safe if you lose this device.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity)
                                .listRowBackground(Color.clear)
                        }
                    }
                }

                Section("Play the Engine") {
                    Picker("Play as", selection: $colorChoice) {
                        ForEach(ColorChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Engine strength", selection: $difficultyRaw) {
                        ForEach(Difficulty.allCases) { level in
                            Text(level.label).tag(level.rawValue)
                        }
                    }

                    Button {
                        activeSession = GameSession(
                            playerColor: colorChoice.resolved,
                            difficulty: Difficulty(rawValue: difficultyRaw) ?? .casual
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

                Section("Appearance") {
                    Picker("Board theme", selection: $boardThemeRaw) {
                        ForEach(BoardTheme.allCases) { theme in
                            HStack {
                                themeSwatch(theme)
                                Text(theme.label)
                            }
                            .tag(theme.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Leaderboard", systemImage: "trophy") {
                        showLeaderboard = true
                    }
                }
            }
        }
        .sheet(isPresented: $showLeaderboard) {
            LeaderboardView()
        }
        .alert("Change Display Name", isPresented: $showRenameDialog) {
            TextField("Display name", text: $nameInput)
                .textInputAutocapitalization(.never)
            Button("Save") {
                let requested = nameInput
                Task {
                    do {
                        try await AccountStore.shared.rename(to: requested)
                    } catch AccountError.server(let status) where status == 400 {
                        renameError = "Names must be 3-24 letters, digits, spaces, _ or -."
                    } catch {
                        renameError = "Couldn't reach the server. Try again later."
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shown to your online opponents and on the leaderboard.")
        }
        .alert("Rename Failed", isPresented: Binding(
            get: { renameError != nil },
            set: { if !$0 { renameError = nil } }
        )) {
            Button("OK") { renameError = nil }
        } message: {
            Text(renameError ?? "")
        }
        .alert("Sign in with Apple Failed", isPresented: Binding(
            get: { signInError != nil },
            set: { if !$0 { signInError = nil } }
        )) {
            Button("OK") { signInError = nil }
        } message: {
            Text(signInError ?? "")
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

    private func handleAppleSignInResult(_ result: Result<ASAuthorization, Error>) {
        isSigningInWithApple = true
        Task {
            do {
                switch result {
                case .success(let authorization):
                    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                        signInError = "Unexpected credential type"
                        return
                    }
                    try await AccountStore.shared.signInWithApple(
                        credential,
                        displayName: credential.fullName.flatMap(formatFullName)
                    )
                case .failure(let error):
                    if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                        signInError = "Sign in with Apple failed: \(error.localizedDescription)"
                    }
                }
            } catch AccountError.server(let status) {
                signInError = "Server error (\(status))"
            } catch {
                signInError = "Couldn't sign in. Try again later."
            }
            isSigningInWithApple = false
        }
    }

    private func formatFullName(_ name: PersonNameComponents) -> String? {
        let formatter = PersonNameComponentsFormatter()
        formatter.style = .default
        let formatted = formatter.string(from: name)
        return formatted.isEmpty ? nil : formatted
    }
}

extension HomeView {
    /// Two-square miniature showing a theme's colors.
    fileprivate func themeSwatch(_ theme: BoardTheme) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(theme.lightSquare)
            Rectangle().fill(theme.darkSquare)
        }
        .frame(width: 24, height: 12)
        .clipShape(RoundedRectangle(cornerRadius: 3))
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
