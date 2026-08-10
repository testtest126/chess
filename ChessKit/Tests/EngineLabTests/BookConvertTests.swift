import ChessKit
import ChessProtocol
import XCTest
@testable import EngineLab

final class BookConvertTests: XCTestCase {
    func testConvertProducesLoadableKeyedRowsWithSameMoves() {
        let compactRows = [
            "|e2e4|100",
            "|d2d4|80",
            "e2e4|e7e5|60",
            "e2e4|c7c5|40",
        ]
        let keyedRows = BookConvert.convert(compactRows: compactRows)
        XCTAssertFalse(keyedRows.isEmpty)

        let source = OpeningBook(compactRows: compactRows)
        let converted = OpeningBook(keyedRows: keyedRows)

        XCTAssertEqual(source.weightedMoves(for: Board()), converted.weightedMoves(for: Board()))

        let afterE4 = Board().making(Move(uci: "e2e4")!)!
        XCTAssertEqual(source.weightedMoves(for: afterE4), converted.weightedMoves(for: afterE4))
    }

    func testConvertSkipsIllegalCompactRowsSameAsDirectLoad() {
        let compactRows = ["e2e4|zz99|5", "|e2e4|10"]
        let keyedRows = BookConvert.convert(compactRows: compactRows)
        let converted = OpeningBook(keyedRows: keyedRows)
        XCTAssertEqual(converted.positionCount, 1)
        XCTAssertEqual(converted.weightedMoves(for: Board()).map(\.move.uci), ["e2e4"])
    }

    func testConvertOfEmptyInputProducesEmptyOutput() {
        XCTAssertTrue(BookConvert.convert(compactRows: []).isEmpty)
    }
}
