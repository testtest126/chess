import ChessKit
import ChessProtocol
import XCTest
@testable import EngineLab

/// TEMPORARY — not part of the PR. Measures the Elo delta between the new
/// tapered eval and the old flat material+PST eval via self-play, at equal
/// search depth so search behavior contributes nothing to the difference.
final class TempMeasurementTests: XCTestCase {
    func testEvalStrengthDelta() {
        let newEval = EngineConfig(label: "new-eval", limit: SearchLimit(depth: 4), legacyEval: false)
        let oldEval = EngineConfig(label: "legacy-eval", limit: SearchLimit(depth: 4), legacyEval: true)
        let result = SelfPlay.playMatch(a: newEval, b: oldEval)
        print("MEASUREMENT depth4: \(result.wins)W \(result.draws)D \(result.losses)L, "
            + "score=\(result.scoreA), Elo=\(result.eloDelta) +/- \(result.eloMargin)")

        let newEval2 = EngineConfig(label: "new-eval", limit: SearchLimit(depth: 5), legacyEval: false)
        let oldEval2 = EngineConfig(label: "legacy-eval", limit: SearchLimit(depth: 5), legacyEval: true)
        let result2 = SelfPlay.playMatch(a: newEval2, b: oldEval2)
        print("MEASUREMENT depth5: \(result2.wins)W \(result2.draws)D \(result2.losses)L, "
            + "score=\(result2.scoreA), Elo=\(result2.eloDelta) +/- \(result2.eloMargin)")
    }
}
