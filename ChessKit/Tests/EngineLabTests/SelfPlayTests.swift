import ChessKit
import ChessProtocol
import XCTest
@testable import EngineLab

final class SelfPlayTests: XCTestCase {
    /// Two identical engines, colors swapped per opening, must net to exactly
    /// even: whatever happens with A as White happens identically with B as
    /// White, so wins and losses cancel. Checks both the fairness of the
    /// color-swap pairing and whole-game determinism. Depth 1 keeps it cheap.
    func testNullMatchIsExactlyBalanced() {
        let config = EngineConfig(label: "depth-1", limit: SearchLimit(depth: 1))
        let openings = Array(Openings.standard.prefix(2))
        let result = SelfPlay.playMatch(a: config, b: config, openings: openings, maxPlies: 80)

        XCTAssertEqual(result.games, openings.count * 2)
        XCTAssertEqual(result.wins, result.losses, "identical engines must net even")
        XCTAssertEqual(result.scoreA, 0.5, accuracy: 1e-9)
        XCTAssertEqual(result.eloDelta, 0, accuracy: 1e-6)
    }

    /// The Elo pipeline points the right way: a deeper-searching engine outscores
    /// a shallower one, giving a positive Elo delta. A robust property (not a
    /// pinned count), so ordinary engine tweaks don't make it noisy.
    func testDeeperEngineOutscoresShallower() {
        let deep = EngineConfig(label: "depth-2", limit: SearchLimit(depth: 2))
        let shallow = EngineConfig(label: "depth-1", limit: SearchLimit(depth: 1))
        let openings = Array(Openings.standard.prefix(2))

        let result = SelfPlay.playMatch(a: deep, b: shallow, openings: openings, maxPlies: 80)
        XCTAssertGreaterThan(result.scoreA, 0.5, "deeper search should score higher")
        XCTAssertGreaterThan(result.eloDelta, 0)
        XCTAssertGreaterThanOrEqual(result.eloMargin, 0)
    }

    /// A game is reproducible: replaying it yields the same result, reason, and
    /// length. Combined with the bench determinism guard, this establishes that
    /// a whole match is reproducible.
    func testGameIsReproducible() {
        let config = EngineConfig(label: "depth-1", limit: SearchLimit(depth: 1))
        let first = SelfPlay.playGame(white: config, black: config, from: Board(), maxPlies: 60)
        let second = SelfPlay.playGame(white: config, black: config, from: Board(), maxPlies: 60)
        XCTAssertEqual(first.result, second.result)
        XCTAssertEqual(first.reason, second.reason)
        XCTAssertEqual(first.plies, second.plies)
    }

    /// Every game terminates with a definite outcome; the ply cap guarantees it
    /// even if the draw rules somehow don't fire first.
    func testGamesAlwaysTerminate() {
        let config = EngineConfig(label: "depth-2", limit: SearchLimit(depth: 2))
        let outcome = SelfPlay.playGame(
            white: config, black: config,
            from: Board(), maxPlies: 30
        )
        XCTAssertLessThanOrEqual(outcome.plies, 30)
    }
}
