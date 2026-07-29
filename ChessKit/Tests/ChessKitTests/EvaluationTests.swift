import XCTest
@testable import ChessKit

/// Coverage for the evaluation upgrade (material + PST was already there):
/// pawn structure (doubled/isolated/passed), king safety (shield, open
/// files), and the tapered king PST (safety-seeking midgame, centralizing
/// endgame). The pure-function tests exercise `Eval`/`PST` directly with
/// controlled inputs so results are exact and confound-free; the
/// `Board.evaluateFast()` tests are integration-level smoke checks that the
/// pieces are actually wired together on a real position.
final class EvaluationTests: XCTestCase {
    // MARK: - Eval.pawnStructureScore (pure function, exact values)

    func testDoubledPawnsArePenalized() {
        // Two white pawns on the a-file (a2, a3), nothing else — also
        // isolated (no b-file pawn) and passed (no black pawns anywhere).
        // No black pawns means there's no cross-side term to confound the
        // arithmetic, so this locks in the exact sum of all three terms.
        let score = Eval.pawnStructureScore(
            whitePawnFiles: [2, 0, 0, 0, 0, 0, 0, 0],
            blackPawnFiles: [0, 0, 0, 0, 0, 0, 0, 0],
            whiteMinRankOnFile: [1, 8, 8, 8, 8, 8, 8, 8],
            blackMaxRankOnFile: [-1, -1, -1, -1, -1, -1, -1, -1],
            whitePawnSquares: [Sq.index(file: 0, rank: 1), Sq.index(file: 0, rank: 2)],
            blackPawnSquares: [],
            endgameFactor: 0
        )
        // doubled: -12×1. isolated: -14×2 (both a-file pawns, no b-file
        // neighbor). passed: rank1 (+5) + rank2 (+10), scale 1.
        XCTAssertEqual(score, -12 - 28 + 15)
    }

    func testIsolatedPawnsScoreWorseThanConnectedPawnsAtEqualMaterial() {
        // Same two pawns, same ranks, same PST cells either way (a4/c4 vs
        // a4/b4 land on identical piece-square values) — only file adjacency
        // differs, isolating the isolated-pawn term from doubled/PST noise.
        let isolated = Eval.pawnStructureScore(
            whitePawnFiles: [1, 0, 1, 0, 0, 0, 0, 0],
            blackPawnFiles: [0, 0, 0, 0, 0, 0, 0, 0],
            whiteMinRankOnFile: [3, 8, 3, 8, 8, 8, 8, 8],
            blackMaxRankOnFile: [-1, -1, -1, -1, -1, -1, -1, -1],
            whitePawnSquares: [Sq.index(file: 0, rank: 3), Sq.index(file: 2, rank: 3)],
            blackPawnSquares: [],
            endgameFactor: 0
        )
        let connected = Eval.pawnStructureScore(
            whitePawnFiles: [1, 1, 0, 0, 0, 0, 0, 0],
            blackPawnFiles: [0, 0, 0, 0, 0, 0, 0, 0],
            whiteMinRankOnFile: [3, 3, 8, 8, 8, 8, 8, 8],
            blackMaxRankOnFile: [-1, -1, -1, -1, -1, -1, -1, -1],
            whitePawnSquares: [Sq.index(file: 0, rank: 3), Sq.index(file: 1, rank: 3)],
            blackPawnSquares: [],
            endgameFactor: 0
        )
        // Both pawns are passed in both scenarios (identical bonus either
        // way — no black pawns to block them), so the whole gap is the
        // isolated penalty applying to both a4 and c4 versus neither.
        XCTAssertEqual(connected - isolated, 2 * Eval.isolatedPawnPenalty)
    }

    func testPassedPawnBonusScalesUpInTheEndgame() {
        // Two connected, unopposed pawns (c4/d4 — neither isolated, both
        // passed) so the isolated-pawn term is zero in both calls and the
        // whole score is passed-pawn bonus, scaled only by `endgameFactor`.
        func score(endgameFactor: Double) -> Int {
            Eval.pawnStructureScore(
                whitePawnFiles: [0, 0, 1, 1, 0, 0, 0, 0],
                blackPawnFiles: [0, 0, 0, 0, 0, 0, 0, 0],
                whiteMinRankOnFile: [8, 8, 3, 3, 8, 8, 8, 8],
                blackMaxRankOnFile: [-1, -1, -1, -1, -1, -1, -1, -1],
                whitePawnSquares: [Sq.index(file: 2, rank: 3), Sq.index(file: 3, rank: 3)],
                blackPawnSquares: [],
                endgameFactor: endgameFactor
            )
        }
        let midgame = score(endgameFactor: 0)
        let endgame = score(endgameFactor: 1)
        XCTAssertGreaterThan(midgame, 0, "two unopposed connected pawns are passed even in the midgame")
        XCTAssertEqual(endgame, 2 * midgame, "passedScale is exactly 1 + endgameFactor")
    }

    func testBlockedPawnGetsNoPassedBonus() {
        // Same white d4 pawn (isolated identically either way — the
        // isolated-pawn term cancels in the difference), only whether a
        // pawn blocks its file ahead differs. No actual black pawn is
        // scored (`blackPawnSquares` stays empty), so nothing on the black
        // side of the ledger can confound the comparison.
        func score(blockerAheadOnDFile: Bool) -> Int {
            Eval.pawnStructureScore(
                whitePawnFiles: [0, 0, 0, 1, 0, 0, 0, 0],
                blackPawnFiles: [0, 0, 0, 0, 0, 0, 0, 0],
                whiteMinRankOnFile: [8, 8, 8, 3, 8, 8, 8, 8],
                blackMaxRankOnFile: blockerAheadOnDFile
                    ? [-1, -1, -1, 5, -1, -1, -1, -1]
                    : [-1, -1, -1, -1, -1, -1, -1, -1],
                whitePawnSquares: [Sq.index(file: 3, rank: 3)],
                blackPawnSquares: [],
                endgameFactor: 1
            )
        }
        let unblocked = score(blockerAheadOnDFile: false)
        let blocked = score(blockerAheadOnDFile: true)
        XCTAssertEqual(unblocked - blocked, Int(Double(Eval.passedPawnByRank[3]) * 2))
    }

    // MARK: - PST.kingBonus (tapering)

    func testKingBonusIsPureMidgameTableAtEndgameFactorZero() {
        let square = Sq.index(file: 6, rank: 0) // g1
        XCTAssertEqual(
            PST.kingBonus(at: square, color: .white, endgameFactor: 0),
            PST.kingMidgame[square]
        )
    }

    func testKingBonusIsPureEndgameTableAtEndgameFactorOne() {
        let square = Sq.index(file: 4, rank: 3) // e4
        XCTAssertEqual(
            PST.kingBonus(at: square, color: .white, endgameFactor: 1),
            PST.kingEndgame[square]
        )
    }

    func testKingBonusRewardsCentralizationOnlyAsPhaseIncreases() {
        // e4 is punished by the midgame table (exposed center) but rewarded
        // by the endgame one (active king) — the blended bonus must cross
        // from worse-than-corner to better-than-corner as the phase shifts.
        let corner = Sq.index(file: 6, rank: 0) // g1
        let center = Sq.index(file: 4, rank: 3) // e4
        let midgameGap = PST.kingBonus(at: center, color: .white, endgameFactor: 0)
            - PST.kingBonus(at: corner, color: .white, endgameFactor: 0)
        let endgameGap = PST.kingBonus(at: center, color: .white, endgameFactor: 1)
            - PST.kingBonus(at: corner, color: .white, endgameFactor: 1)
        XCTAssertLessThan(midgameGap, 0, "center is worse than the corner with pieces still on")
        XCTAssertGreaterThan(endgameGap, 0, "center is better than the corner once material is off")
    }

    // MARK: - Board.evaluateFast() integration

    func testShelteredKingScoresBetterThanExposedKingAtEqualMaterial() {
        // Same material (Q+2R+8P per side) and the same king square (g1) in
        // both positions; the only difference is whether White's f/g/h pawns
        // are still on the second rank (an intact shield) or pushed to the
        // fourth (none of them shielding anymore). Enough non-pawn material
        // stays on the board that endgameFactor is well short of 1, so the
        // king-safety term isn't faded all the way out.
        let sheltered = Board(fen: "r2q1rk1/pppppppp/8/8/8/8/PPPPPPPP/R2Q1RK1 w - - 0 1")!
        let exposed = Board(fen: "r2q1rk1/pppppppp/8/8/5PPP/8/PPPPP3/R2Q1RK1 w - - 0 1")!
        XCTAssertGreaterThan(sheltered.evaluateFast(), exposed.evaluateFast())
    }

    func testCentralizedKingBeatsCorneredKingInABarePawnEndgame() {
        // Bare king-and-pawn endgame: no other material at all, so
        // endgameFactor is exactly 1 and the tapered king table alone
        // decides which king placement scores better. Kings are kept well
        // apart (not adjacent) so the position is a sane one to evaluate.
        let centralized = Board(fen: "k7/8/8/8/3K4/8/4P3/8 w - - 0 1")!
        let cornered = Board(fen: "k7/8/8/8/8/8/4P3/7K w - - 0 1")!
        XCTAssertGreaterThan(centralized.evaluateFast(), cornered.evaluateFast())
    }

    func testConnectedPawnsBeatDoubledPawnsOnARealBoard() {
        let connected = Board(fen: "4k3/8/8/8/8/8/PP6/4K3 w - - 0 1")!
        let doubled = Board(fen: "4k3/8/8/8/8/P7/P7/4K3 w - - 0 1")!
        XCTAssertGreaterThan(connected.evaluateFast(), doubled.evaluateFast())
    }
}
