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

    // MARK: - Weighted moves

    func testRepeatedLineAccumulatesWeight() {
        let book = OpeningBook(lines: [
            "e2e4 e7e5",
            "e2e4 e7e5",
            "e2e4 c7c5",
        ])
        let weighted = book.weightedMoves(for: Board())
        XCTAssertEqual(weighted.count, 1) // one distinct move: e2e4
        XCTAssertEqual(weighted[0].weight, 3) // seen in all three lines

        var board = Board()
        board.apply(Move(uci: "e2e4")!)
        let replies = Dictionary(uniqueKeysWithValues: book.weightedMoves(for: board).map { ($0.move.uci, $0.weight) })
        XCTAssertEqual(replies["e7e5"], 2)
        XCTAssertEqual(replies["c7c5"], 1)
    }

    func testRandomMoveIsDeterministicForSameSeed() {
        let book = OpeningBook(lines: ["e2e4 e7e5", "d2d4 d7d5", "g1f3 g8f6"])
        for seed: UInt64 in [0, 1, 42, .max] {
            let first = book.randomMove(for: Board(), seed: seed)
            let second = book.randomMove(for: Board(), seed: seed)
            XCTAssertEqual(first, second, "seed \(seed) should always pick the same move")
        }
    }

    func testRandomMovePrefersHeavierWeightOverManySeeds() {
        // 9:1 weight split between e2e4 and c2c4 — over many independent
        // seeds, the heavier move should come out far more often, not ~50/50.
        let lines = Array(repeating: "e2e4", count: 9) + ["c2c4"]
        let book = OpeningBook(lines: lines)
        var e4Count = 0
        for seed: UInt64 in 0..<500 {
            if book.randomMove(for: Board(), seed: seed)?.uci == "e2e4" { e4Count += 1 }
        }
        XCTAssertGreaterThan(e4Count, 350, "e2e4 (weight 9) should be picked far more than c2c4 (weight 1)")
    }

    func testRandomMoveOutOfBookReturnsNil() {
        let book = OpeningBook(lines: ["e2e4 e7e5"])
        var board = Board()
        board.apply(Move(uci: "d2d4")!)
        XCTAssertNil(book.randomMove(for: board, seed: 7))
    }

    func testCompactRowsBuildsWeightedBookAndSkipsMalformedRows() {
        let book = OpeningBook(compactRows: [
            "|e2e4|100",
            "|d2d4|80",
            "e2e4|e7e5|60",
            "not a valid row",
            "e2e4|zz99|5", // illegal move, skipped
            "d2d4 g8f6|c2c4|40",
        ])
        let root = Dictionary(uniqueKeysWithValues: book.weightedMoves(for: Board()).map { ($0.move.uci, $0.weight) })
        XCTAssertEqual(root["e2e4"], 100)
        XCTAssertEqual(root["d2d4"], 80)

        var afterE4 = Board()
        afterE4.apply(Move(uci: "e2e4")!)
        XCTAssertEqual(book.weightedMoves(for: afterE4).map(\.move.uci), ["e7e5"])

        var afterD4Nf6 = Board()
        afterD4Nf6.apply(Move(uci: "d2d4")!)
        afterD4Nf6.apply(Move(uci: "g8f6")!)
        XCTAssertEqual(book.weightedMoves(for: afterD4Nf6).map(\.move.uci), ["c2c4"])
    }

    func testLargeBookHasKnownOpeningWithLegalMoves() {
        let book = OpeningBook.large
        XCTAssertGreaterThan(book.positionCount, 100, "the generated book should have real content bundled")

        let startMoves = book.weightedMoves(for: Board())
        XCTAssertGreaterThan(startMoves.count, 1)
        // e2e4 is the single most-played first move in the source database.
        XCTAssertTrue(startMoves.contains { $0.move.uci == "e2e4" })

        let board = Board()
        for weighted in startMoves {
            XCTAssertTrue(board.isLegal(weighted.move), "\(weighted.move.uci) should be legal")
            XCTAssertGreaterThan(weighted.weight, 0)
        }
    }

    func testLargeBookCoversDeeperThanTheOldTenPlyCap() {
        // The Ruy Lopez main line through 12 plies (1.e4 e5 2.Nf3 Nc6 3.Bb5
        // a6 4.Ba4 Nf6 5.O-O Be7 6.Re1 b5) -- one ply past OpeningBook
        // .standard's own scope and beyond the previous 10-ply-deep
        // generated book, still resolving to a real book move confirms the
        // Lichess-sourced book's 14-ply depth, not just its row count.
        let book = OpeningBook.large
        var deep = Board()
        for uci in ["e2e4", "e7e5", "g1f3", "b8c6", "f1b5", "a7a6", "b5a4", "g8f6",
                    "e1g1", "f8e7", "f1e1", "b7b5"] {
            deep.apply(Move(uci: uci)!)
        }
        let replies = book.weightedMoves(for: deep)
        XCTAssertFalse(replies.isEmpty, "book should still have a reply 12 plies deep")
        XCTAssertTrue(replies.contains { $0.move.uci == "a4b3" }, "a4b3 is the well-known main line retreat here")
    }
}
