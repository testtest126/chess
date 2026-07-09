import Foundation
import Observation
import ChessKit
import ChessProtocol

/// Engine strength presets exposed in the UI, mapped to search limits.
enum Difficulty: String, CaseIterable, Codable, Identifiable {
    case beginner, casual, club, expert

    var id: String { rawValue }

    var label: String {
        switch self {
        case .beginner: return "Beginner"
        case .casual: return "Casual"
        case .club: return "Club"
        case .expert: return "Expert"
        }
    }

    var limit: SearchLimit {
        switch self {
        case .beginner: return SearchLimit(depth: 1)
        case .casual: return SearchLimit(depth: 2)
        case .club: return SearchLimit(depth: 3, maxNodes: 150_000)
        case .expert: return SearchLimit(depth: 4, maxNodes: 400_000)
        }
    }
}

/// Live state for one game against the engine. Owns the `Game`, runs engine
/// searches off the main actor, and exposes everything the views observe.
@MainActor
@Observable
final class GameSession: Identifiable {
    let id = UUID()
    let playerColor: PieceColor
    let difficulty: Difficulty

    private(set) var game: Game
    private(set) var isEngineThinking = false

    private let engine = NegamaxEngine()

    init(playerColor: PieceColor, difficulty: Difficulty) {
        self.playerColor = playerColor
        self.difficulty = difficulty
        self.game = Game()
    }

    var board: Board { game.board }
    var lastMove: Move? { game.history.last?.move }
    var isPlayerTurn: Bool { !game.isOver && board.sideToMove == playerColor && !isEngineThinking }

    /// Kick off the engine's first move when the player is Black.
    func start() {
        engineMoveIfNeeded()
    }

    func playPlayerMove(_ move: Move) {
        guard isPlayerTurn else { return }
        guard (try? game.play(move)) != nil else { return }
        engineMoveIfNeeded()
    }

    func resign() {
        guard !game.isOver else { return }
        game.end(
            result: playerColor == .white ? .blackWins : .whiteWins,
            reason: .resignation
        )
    }

    private func engineMoveIfNeeded() {
        guard !game.isOver, board.sideToMove == playerColor.opposite, !isEngineThinking else { return }
        isEngineThinking = true

        let position = board
        let engine = self.engine
        let limit = difficulty.limit

        Task {
            let started = ContinuousClock.now
            let result = await Task.detached(priority: .userInitiated) {
                engine.search(position, limit: limit)
            }.value

            // Instant replies feel broken; give the engine a beat.
            let elapsed = ContinuousClock.now - started
            if elapsed < .milliseconds(400) {
                try? await Task.sleep(for: .milliseconds(400) - elapsed)
            }

            isEngineThinking = false
            // The game may have been resigned while searching.
            guard !game.isOver, game.board == position, let move = result.bestMove else { return }
            try? game.play(move)
        }
    }
}
