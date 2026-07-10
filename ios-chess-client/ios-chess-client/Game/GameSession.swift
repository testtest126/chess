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
        case .casual: return SearchLimit(depth: 2, moveTime: 0.5)
        case .club: return SearchLimit(depth: 4, moveTime: 1.0)
        case .expert: return SearchLimit(depth: 6, moveTime: 2.5)
        }
    }

    /// Chance (percent) that this level ignores the engine and plays a random
    /// legal move — beginners are erratic, and it keeps games varied.
    var blunderChance: Int {
        switch self {
        case .beginner: return 30
        case .casual: return 10
        case .club, .expert: return 0
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
    private(set) var hintMove: Move?
    private(set) var isFindingHint = false

    /// Book-backed so games open with variety instead of one deterministic line.
    private let engine = NegamaxEngine(book: .standard)

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
        hintMove = nil
        engineMoveIfNeeded()
    }

    /// Rewinds the player's last move (and the engine's reply to it).
    var canTakeBack: Bool {
        !game.isOver && !isEngineThinking && game.moveCount >= 2 && board.sideToMove == playerColor
    }

    func takeBack() {
        guard canTakeBack else { return }
        hintMove = nil
        if let rewound = try? Game.from(uciMoves: game.uciMoves.dropLast(2).map { $0 }) {
            game = rewound
        }
    }

    /// Asks the engine what it would play for the player; shown on the board.
    func requestHint() {
        guard isPlayerTurn, hintMove == nil, !isFindingHint else { return }
        isFindingHint = true
        let position = board
        let engine = self.engine

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                engine.search(position, limit: SearchLimit(depth: 4, moveTime: 1.0))
            }.value
            isFindingHint = false
            // Only show it if the position hasn't moved on meanwhile.
            if game.board == position {
                hintMove = result.bestMove
            }
        }
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
        let blunderChance = difficulty.blunderChance

        Task {
            let started = ContinuousClock.now
            let result = await Task.detached(priority: .userInitiated) {
                // Lower levels sometimes play a random legal move instead of
                // the engine's choice — erratic like the humans they imitate.
                if blunderChance > 0, Int.random(in: 0..<100) < blunderChance,
                   let lapse = position.legalMoves().randomElement() {
                    return SearchResult(bestMove: lapse, scoreCentipawns: 0, depth: 0, nodes: 0)
                }
                return engine.search(position, limit: limit)
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
