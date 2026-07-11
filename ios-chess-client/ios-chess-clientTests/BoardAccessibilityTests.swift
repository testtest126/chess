import Testing
import ChessKit
@testable import ios_chess_client

/// The VoiceOver value string for board squares mirrors every visual
/// highlight state (audit #83, finding P1.2).
struct BoardAccessibilityTests {
    // ChessKit square indices (file a=0…h=7, rank 1=0…8=7).
    private let e2 = Sq.index(file: 4, rank: 1)
    private let e4 = Sq.index(file: 4, rank: 3)
    private let a1 = Sq.index(file: 0, rank: 0)
    private let e1 = Sq.index(file: 4, rank: 0)

    private func value(
        square: Int, selected: Int? = nil, legalTargets: Set<Int> = [],
        lastMove: Move? = nil, hintMove: Move? = nil, checkedKing: Int? = nil
    ) -> String {
        BoardView.accessibilityValue(
            square: square, selected: selected, legalTargets: legalTargets,
            lastMove: lastMove, hintMove: hintMove, checkedKing: checkedKing
        )
    }

    @Test func plainSquareHasEmptyValue() {
        #expect(value(square: a1) == "")
    }

    @Test func selectedSquareSaysSelected() {
        #expect(value(square: e2, selected: e2) == "selected")
    }

    @Test func legalTargetSaysPossibleMove() {
        #expect(value(square: e4, selected: e2, legalTargets: [e4]) == "possible move")
    }

    @Test func lastMoveMarksBothEnds() {
        let move = Move(from: e2, to: e4)
        #expect(value(square: e2, lastMove: move) == "last move")
        #expect(value(square: e4, lastMove: move) == "last move")
        #expect(value(square: a1, lastMove: move) == "")
    }

    @Test func checkedKingSaysInCheck() {
        #expect(value(square: e1, checkedKing: e1) == "in check")
    }

    @Test func statesCompose() {
        // A square can be a legal target of the selection AND part of the
        // last move (e.g. re-capturing on the same square).
        let last = Move(from: a1, to: e4)
        #expect(value(square: e4, selected: e2, legalTargets: [e4], lastMove: last)
                == "possible move, last move")
    }

    @Test func hintMarksSuggestedSquares() {
        let hint = Move(from: e2, to: e4)
        #expect(value(square: e4, hintMove: hint) == "hint")
    }
}
