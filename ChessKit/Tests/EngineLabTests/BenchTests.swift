import ChessKit
import ChessProtocol
import XCTest
@testable import EngineLab

final class BenchTests: XCTestCase {
    /// The CI node budget. Small so `swift test` stays fast (the engine only
    /// searches a few thousand nodes/sec in a debug build), but large enough
    /// that most positions reach several plies, exercising real search.
    static let ciNodeBudget = 2000

    /// The signature the suite produces at `ciNodeBudget`. Pinned so any change
    /// in search behavior trips CI; update it in the same PR that changes the
    /// engine — that diff is the review signal. Engine evaluation is pure
    /// integer, so the value is byte-identical across machines and across
    /// debug/release builds (verified).
    static let signatureAtCIBudget: UInt64 = 0xcd7f_a918_c21e_afc2

    /// Every suite FEN must parse and be a real, non-terminal position — a
    /// typo'd or already-checkmated FEN would silently search nothing.
    func testSuitePositionsAreValidAndPlayable() {
        XCTAssertEqual(BenchSuite.positions.count, 20)
        for position in BenchSuite.positions {
            let board = Board(fen: position.fen)
            XCTAssertNotNil(board, "unparseable FEN for \(position.name): \(position.fen)")
            XCTAssertFalse(
                board?.legalMoves().isEmpty ?? true,
                "\(position.name) has no legal moves"
            )
        }
    }

    /// The determinism regression guard, in one shot: two independent runs must
    /// agree with each other on every observable, and the signature must match
    /// the pinned snapshot. If the two runs disagree, the engine stopped being
    /// deterministic; if they agree but differ from the snapshot, search
    /// behavior changed.
    func testBenchIsDeterministicAndMatchesSnapshot() {
        let limit = Bench.nodeLimit(Self.ciNodeBudget)
        let first = Bench.run(limit: limit)
        let second = Bench.run(limit: limit)

        XCTAssertEqual(first.totalNodes, second.totalNodes)
        XCTAssertEqual(first.perPosition.count, second.perPosition.count)
        for (a, b) in zip(first.perPosition, second.perPosition) {
            XCTAssertEqual(a.nodes, b.nodes, "\(a.name) nodes")
            XCTAssertEqual(a.depth, b.depth, "\(a.name) depth")
            XCTAssertEqual(a.scoreCentipawns, b.scoreCentipawns, "\(a.name) score")
            XCTAssertEqual(a.bestMove, b.bestMove, "\(a.name) bestmove")
        }

        XCTAssertEqual(first.signature, second.signature)
        XCTAssertEqual(
            first.signature, Self.signatureAtCIBudget,
            "bench signature changed — if this is an intentional engine change, update "
                + "signatureAtCIBudget to 0x\(String(first.signature, radix: 16))"
        )
    }

    /// Fixed-depth bench is deterministic too, and there the *total node count*
    /// is itself the behavioral fingerprint (not pinned to a budget). Depth 2
    /// over a subset keeps this cheap.
    func testFixedDepthBenchIsStable() {
        let subset = Array(BenchSuite.positions.prefix(8))
        let a = Bench.run(limit: SearchLimit(depth: 2), positions: subset)
        let b = Bench.run(limit: SearchLimit(depth: 2), positions: subset)
        XCTAssertEqual(a.totalNodes, b.totalNodes)
        XCTAssertEqual(a.signature, b.signature)
        XCTAssertGreaterThan(a.totalNodes, 0)
    }
}
