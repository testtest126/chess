import SwiftUI
import SwiftData
import ChessKit
import ChessOnline
import AuthenticationServices
import CryptoKit

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
    @State private var showDeleteAccountConfirmation = false
    @State private var isDeletingAccount = false
    @State private var deleteAccountError: String?
    /// Prefetched single-use nonce for Sign in with Apple; its SHA-256 is
    /// bound into the authorization request for replay protection.
    @State private var pendingAppleNonce: String?
    @AppStorage(BoardTheme.storageKey) private var boardThemeRaw = BoardTheme.classic.rawValue

    enum ColorChoice: String, CaseIterable, Identifiable {
        case white, black, random
        var id: String { rawValue }
        var label: String {
            switch self {
            case .white: return PieceColor.white.localizedName
            case .black: return PieceColor.black.localizedName
            case .random: return String(localized: "Random", comment: "Play as a randomly assigned side")
            }
        }

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
                    AdaptiveSegmentedPicker(title: "Time control", selection: $timeControlRaw) {
                        ForEach(TimeControl.allCases, id: \.rawValue) { control in
                            Text(control.label).tag(control.rawValue)
                        }
                    }

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
                            // Bind the server-issued nonce (hashed, per
                            // Apple's convention) so the identity token
                            // can't be replayed. Prefetched in .task below.
                            if let raw = pendingAppleNonce {
                                request.nonce = Self.sha256Hex(raw)
                            }
                        } onCompletion: { result in
                            handleAppleSignInResult(result, rawNonce: pendingAppleNonce)
                        }
                        .frame(height: 40)
                        .disabled(isSigningInWithApple)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 2, trailing: 16))
                        .listRowBackground(Color.clear)
                        .task {
                            if pendingAppleNonce == nil {
                                pendingAppleNonce = try? await AccountStore.shared.fetchAppleNonce()
                            }
                        }

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
                            // .secondary, not .tertiary: this is informative
                            // text and tertiary fails WCAG contrast on the
                            // grouped background (audit #83, finding P2.4).
                            Text(AccountStore.shared.displayName == nil
                                ? "Recovers your account if you've played before."
                                : "Keeps your rating safe if you lose this device.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                // Guarantee wrapping at large type sizes;
                                // the audit flags this row as clippable (#83).
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity)
                                .listRowBackground(Color.clear)
                        }
                    }
                }

                // The account area (App Review 5.1.1(v) wants deletion
                // findable here). Only shown once an account exists —
                // there is nothing to delete before the first online game.
                if AccountStore.shared.userID != nil {
                    Section("Account") {
                        Button(role: .destructive) {
                            showDeleteAccountConfirmation = true
                        } label: {
                            if isDeletingAccount {
                                HStack(spacing: 12) {
                                    ProgressView()
                                        .scaleEffect(0.9)
                                    Text("Deleting Account…")
                                }
                            } else {
                                Label("Delete Account", systemImage: "trash")
                            }
                        }
                        .disabled(isDeletingAccount)
                    }
                }

                Section("Play the Engine") {
                    AdaptiveSegmentedPicker(title: "Play as", selection: $colorChoice) {
                        ForEach(ColorChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }

                    Picker(selection: $difficultyRaw) {
                        ForEach(Difficulty.allCases) { level in
                            Text(level.label).tag(level.rawValue)
                        }
                    } label: {
                        // Wrap instead of clipping at accessibility type
                        // sizes — the audit flags the one-line label (#83).
                        Text("Engine strength")
                            .fixedSize(horizontal: false, vertical: true)
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
            // Offline-first history: local rows are already on screen; this
            // fills in online games from other devices or past installs.
            .task { await GameHistorySync.sync(into: modelContext) }
            .refreshable { await GameHistorySync.sync(into: modelContext) }
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
                        renameError = String(localized: "Names must be 3-24 letters, digits, spaces, _ or -.",
                                             comment: "Rename validation error")
                    } catch {
                        renameError = String(localized: "Couldn't reach the server. Try again later.",
                                             comment: "Rename network error")
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
        // Explicit confirmation before the irreversible step, as Apple's
        // account-deletion guidance asks. Note for UI tests: on iOS 26 this
        // renders as a popover whose Cancel button is not exposed to the
        // accessibility tree — key on the destructive button instead.
        .confirmationDialog(
            "Delete your account?",
            isPresented: $showDeleteAccountConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive) {
                deleteAccount()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
            Your online identity, rating, and sign-in are permanently erased; \
            finished games are kept anonymized for your opponents' history. \
            This cannot be undone.
            """)
        }
        .alert("Couldn't Delete Account", isPresented: Binding(
            get: { deleteAccountError != nil },
            set: { if !$0 { deleteAccountError = nil } }
        )) {
            Button("OK") { deleteAccountError = nil }
        } message: {
            Text(deleteAccountError ?? "")
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

    /// Runs the deletion; `AccountStore` wipes the Keychain credential and
    /// resets local account state on success. The section disappears on its
    /// own once `userID` becomes nil.
    private func deleteAccount() {
        isDeletingAccount = true
        Task {
            do {
                try await AccountStore.shared.deleteAccount()
            } catch {
                deleteAccountError = String(
                    localized: "Couldn't reach the server. Your account was not deleted — try again later.",
                    comment: "Account deletion network/server failure"
                )
            }
            isDeletingAccount = false
        }
    }

    private func handleAppleSignInResult(_ result: Result<ASAuthorization, Error>, rawNonce: String?) {
        isSigningInWithApple = true
        // Nonces are single-use: whatever happens next, this one is spent.
        pendingAppleNonce = nil
        Task {
            defer {
                // Refetch so the button is ready for another attempt.
                Task { pendingAppleNonce = try? await AccountStore.shared.fetchAppleNonce() }
            }
            do {
                switch result {
                case .success(let authorization):
                    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                        signInError = String(localized: "Unexpected credential type", comment: "Sign in with Apple error")
                        return
                    }
                    guard let rawNonce else {
                        signInError = String(localized: "Couldn't reach the server to secure the sign-in. Try again.",
                                             comment: "Sign in with Apple error when the nonce prefetch failed")
                        return
                    }
                    try await AccountStore.shared.signInWithApple(
                        credential,
                        displayName: credential.fullName.flatMap(formatFullName),
                        rawNonce: rawNonce
                    )
                case .failure(let error):
                    if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                        signInError = String(localized: "Sign in with Apple failed: \(error.localizedDescription)",
                                             comment: "Sign in with Apple error; parameter is the system error message")
                    }
                }
            } catch AccountError.server(let status) {
                signInError = String(localized: "Server error (\(status))", comment: "Account error; parameter is the HTTP status code")
            } catch {
                signInError = String(localized: "Couldn't sign in. Try again later.", comment: "Sign in with Apple error")
            }
            isSigningInWithApple = false
        }
    }

    /// SHA-256 hex — Apple's convention for the authorization request nonce.
    static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
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

/// Segmented picker that falls back to the default menu style at
/// accessibility type sizes: UISegmentedControl never scales its labels with
/// Dynamic Type, so the segments become unreadable exactly when the user has
/// asked for bigger text (#83, audit item 5).
private struct AdaptiveSegmentedPicker<SelectionValue: Hashable, Options: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    let title: LocalizedStringKey
    @Binding var selection: SelectionValue
    @ViewBuilder var options: Options

    var body: some View {
        let picker = Picker(title, selection: $selection) { options }
        if typeSize.isAccessibilitySize {
            picker
        } else {
            picker.pickerStyle(.segmented)
        }
    }
}

struct SavedGameRow: View {
    let saved: SavedGame

    /// "As White vs Guest-1234 · 12 moves · Blitz"; the control tag is absent
    /// for engine games and online rows that predate selectable controls.
    /// `control.label` is already localized, so it composes verbatim onto the
    /// localized base line.
    private var detail: Text {
        let base = Text("As \(saved.playerColor.localizedName) vs \(saved.opponentDescription) · ^[\((saved.moveCount + 1) / 2) move](inflect: true)")
        guard let control = saved.timeControl else { return base }
        return base + Text(verbatim: " · \(control.label)")
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(saved.playerOutcome) \(saved.endReasonDescription)")
                    .font(.headline)
                detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(saved.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    HomeView()
        .modelContainer(for: SavedGame.self, inMemory: true)
}
