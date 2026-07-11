import XCTest
@testable import ChessKit
@testable import ChessProtocol

final class OpeningBookTests: XCTestCase {
    func testEmptyBookReturnsNoMoves() {
        let book = OpeningBook(lines: [])
        XCTAssertEqual(book.positionCount, 0)
        XCTAssertTrue(book.moves(for: Board()).isEmpty)
    }

    func testSingleLineProducesMovesForEachPosition() {
        let book = OpeningBook(lines: ["e2e4 e7e5 g1f3"])
        XCTAssertGreaterThan(book.positionCount, 0)

        // Starting position should have e2e4 as a book move.
        let startMoves = book.moves(for: Board())
        XCTAssertEqual(startMoves.count, 1)
        XCTAssertEqual(startMoves[0].uci, "e2e4")

        // After 1. e4, e7e5 should be a book move.
        var board = Board()
        board.apply(Move(uci: "e2e4")!)
        let afterE4 = book.moves(for: board)
        XCTAssertEqual(afterE4.count, 1)
        XCTAssertEqual(afterE4[0].uci, "e7e5")
    }

    func testMultipleLinesForSamePositionMerge() {
        let book = OpeningBook(lines: [
            "e2e4 e7e5",
            "e2e4 c7c5",
        ])
        // After 1. e4, both e5 and c5 should be book moves.
        var board = Board()
        board.apply(Move(uci: "e2e4")!)
        let moves = book.moves(for: board)
        XCTAssertEqual(moves.count, 2)
        let ucis = Set(moves.map(\.uci))
        XCTAssertTrue(ucis.contains("e7e5"))
        XCTAssertTrue(ucis.contains("c7c5"))
    }

    func testIllegalMoveEndsLine() {
        // "e2e5" is illegal from the starting position.
        let book = OpeningBook(lines: ["e2e5 e7e5"])
        XCTAssertEqual(book.positionCount, 0)
        XCTAssertTrue(book.moves(for: Board()).isEmpty)
    }

    func testOutOfBookPositionReturnsEmpty() {
        let book = OpeningBook(lines: ["e2e4 e7e5"])
        // Position after 1. d4 is not in the book.
        var board = Board()
        board.apply(Move(uci: "d2d4")!)
        XCTAssertTrue(book.moves(for: board).isEmpty)
    }

    func testDuplicateMovesAreNotRepeated() {
        let book = OpeningBook(lines: [
            "e2e4 e7e5",
            "e2e4 e7e5 g1f3",
        ])
        // Starting position should have e2e4 exactly once.
        let moves = book.moves(for: Board())
        XCTAssertEqual(moves.count, 1)
    }

    func testStandardBookHasKnownOpenings() {
        let book = OpeningBook.standard
        XCTAssertGreaterThan(book.positionCount, 0)

        // Starting position should have multiple book moves.
        let startMoves = book.moves(for: Board())
        XCTAssertGreaterThan(startMoves.count, 1)

        // All book moves from the starting position should be legal.
        let board = Board()
        for move in startMoves {
            XCTAssertTrue(board.isLegal(move), "\(move.uci) should be legal")
        }
    }

    func testTranspositionHitsBook() {
        // Two move orders reaching the same position should hit the same book entry.
        let book = OpeningBook(lines: [
            "e2e4 e7e6 d2d4 d7d5",
            "d2d4 e7e6 e2e4 d7d5",
        ])
        // After 1. e4 e6 2. d4 and 1. d4 e6 2. e4 — same position,
        // so d7d5 should appear (only once).
        var board = Board()
        board.apply(Move(uci: "e2e4")!)
        board.apply(Move(uci: "e7e6")!)
        board.apply(Move(uci: "d2d4")!)
        let moves = book.moves(for: board)
        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves[0].uci, "d7d5")
    }
}
