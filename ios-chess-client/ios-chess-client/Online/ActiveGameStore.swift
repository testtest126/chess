import Foundation
import Observation

/// Remembers that the player has an online game in progress so the home screen
/// can offer to resume it after they leave the match screen or relaunch the app.
///
/// The server keeps the authoritative game alive across brief disconnects and
/// app restarts (see the reconnect path in the server's GameCoordinator); this
/// is only a local hint that such a game exists. `OnlineGameSession` keeps it in
/// sync from the authoritative message stream: a game start records the
/// opponent, and reaching game-over — or being placed back in the matchmaking
/// queue, which means the server has no game for us — clears it.
@MainActor
@Observable
final class ActiveGameStore {
    static let shared = ActiveGameStore()

    private static let opponentKey = "active_online_game_opponent"

    /// The opponent's name while a game is live, or nil when there is none.
    private(set) var opponentName: String?

    var hasActiveGame: Bool { opponentName != nil }

    init() {
        opponentName = UserDefaults.standard.string(forKey: Self.opponentKey)
    }

    /// Record that a live online game is in progress against `opponent`.
    func begin(opponent: String) {
        guard opponentName != opponent else { return }
        opponentName = opponent
        UserDefaults.standard.set(opponent, forKey: Self.opponentKey)
    }

    /// Forget the active game (it finished, or is no longer resumable).
    func clear() {
        guard opponentName != nil else { return }
        opponentName = nil
        UserDefaults.standard.removeObject(forKey: Self.opponentKey)
    }
}
