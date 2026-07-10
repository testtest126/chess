import AVFoundation
import ChessKit

/// Plays the small bundled game sounds. Uses the `.ambient` audio session
/// category so the silent switch mutes everything and background audio from
/// other apps keeps playing.
@MainActor
enum SoundPlayer {
    enum Effect: String, CaseIterable {
        case move
        case capture
        case gameEnd = "game_end"
    }

    private static var players: [Effect: AVAudioPlayer] = [:]
    private static var isConfigured = false

    static func play(_ effect: Effect) {
        configureIfNeeded()
        guard let player = players[effect] else { return }
        player.currentTime = 0
        player.play()
    }

    /// Move or capture, decided from the board the move is about to hit.
    static func playMove(_ move: Move, on board: Board) {
        let isCapture = board[move.to] != nil
            || (board[move.from]?.kind == .pawn && move.to == board.enPassantSquare)
        play(isCapture ? .capture : .move)
    }

    private static func configureIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        for effect in Effect.allCases {
            guard let url = Bundle.main.url(forResource: effect.rawValue, withExtension: "wav") else { continue }
            let player = try? AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            player?.volume = 0.6
            players[effect] = player
        }
    }
}
