import XCTest
@testable import ChessKit

/// Hand-verified Static Exchange Evaluation cases: a clean win, a losing
/// capture, an equal trade, and a battery/x-ray position that only a
/// correct implementation (one that recomputes attackers against the
/// reduced occupancy, picking up a piece revealed behind a captured
/// blocker) gets right — a naive "attackers at the start only" SEE would
/// return a different, wrong number on that last one (spelled out in the
/// test itself).
final class SEETests: XCTestCase {
    func testWinningUndefendedCaptureIsPositive() {
        // White queen takes an undefended pawn: a clean +100, nothing to
        // recapture with.
        let board = Board(fen: "4k3/8/8/8/3p4/8/8/3QK3 w - - 0 1")!
        let move = Move(uci: "d1d4")!
        XCTAssertEqual(board.see(move), 100)
    }

    func testLosingCaptureIsNegative() {
        // White queen takes a pawn defended by another pawn: +100 for the
        // pawn, then -900 losing the queen to the recapture. Net -800 —
        // the textbook "don't grab the defended pawn with your queen" case.
        let board = Board(fen: "4k3/8/3p1p2/4p3/8/8/8/4QK2 w - - 0 1")!
        let move = Move(uci: "e1e5")!
        XCTAssertEqual(board.see(move), -800)
    }

    func testEqualRookTradeIsZero() {
        // Rook takes rook, recaptured by rook: a dead-even trade nets 0.
        let board = Board(fen: "3kr3/8/8/4r3/8/8/8/4RK2 w - - 0 1")!
        let move = Move(uci: "e1e5")!
        XCTAssertEqual(board.see(move), 0)
    }

    func testBatteryXRayAttackerIsPickedUpAfterFrontPieceIsCaptured() {
        // White has two rooks doubled on the e-file (e1 behind e2); only
        // the front rook (e2) can initially reach e5 — e1's rook is blocked
        // by its own rook on e2, so `attackers(to:by:excluding:)` must NOT
        // report it as an e5 attacker yet. Black has one rook (e8)
        // defending e5's target rook.
        //
        // Full exchange: Re2xRe5 (+500), ...Re8xe5 recaptures the rook that
        // just captured (white's material so far: -500+500=0 relative to
        // before), Re1xe5 via the newly-opened file recaptures Black's
        // rook (+500 more) — the x-ray attacker is exactly what makes this
        // last recapture possible. Final result: White nets a whole rook,
        // +500. A SEE that only looked at e5's attackers *before* any
        // capture (missing e1's rook, since it starts blocked) would stop
        // after Black's recapture and return 0 instead — this is the
        // discriminating case for x-ray correctness, not just a smoke test.
        let board = Board(fen: "3kr3/8/8/4r3/8/8/4R3/4RK2 w - - 0 1")!
        let move = Move(uci: "e2e5")!
        XCTAssertEqual(board.see(move), 500)
    }

    func testEnPassantCaptureUsesThePawnsValueNotTheEmptyDestination() {
        // The captured pawn sits beside the capturer, not on `move.to` — a
        // naive `squares[move.to]` read would see an empty square and score
        // this as a (wrong) zero-value "capture".
        let board = Board(fen: "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1")!
        let move = Move(uci: "e5d6")!
        XCTAssertEqual(board.see(move), 100)
    }

    func testUndefendedRecaptureStillFavorsTheInitiator() {
        // A capture with no recapture available at all (edge case: `see`
        // must terminate cleanly with a one-element gain array).
        let board = Board(fen: "7k/8/8/8/8/8/8/1Kn5 w - - 0 1")!
        let move = Move(uci: "b1c1")!
        XCTAssertEqual(board.see(move), PieceKind.knight.centipawnValue)
    }
}
