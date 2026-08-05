import ChessKit
import XCTest
@testable import EngineLab

final class EPDTests: XCTestCase {
    func testNormalizedFENPadsMissingCounters() {
        // A bare 4-field EPD position (no halfmove/fullmove clock).
        XCTAssertEqual(
            EPD.normalizedFEN("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -"),
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
        )
    }

    func testNormalizedFENLeavesFullFENAlone() {
        let full = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
        XCTAssertEqual(EPD.normalizedFEN(full), full)
    }

    func testNormalizedFENDropsTrailingOpcodes() {
        XCTAssertEqual(
            EPD.normalizedFEN("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 bm e4; id \"pos1\";"),
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
        )
    }

    func testNormalizedFENRejectsTooFewFields() {
        XCTAssertNil(EPD.normalizedFEN("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w"))
    }

    func testLoadOpeningsParsesAFileSkippingBadLines() throws {
        let text = """
        rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1
        not a fen at all
        rn1qkbnr/ppp1pppp/8/3p1b2/2P5/1P6/P2PPPPP/RNBQKBNR w KQkq - 0 3

        """
        let path = NSTemporaryDirectory() + "epd-test-\(UUID().uuidString).epd"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let openings = EPD.loadOpenings(from: path)
        XCTAssertEqual(openings.count, 2, "the malformed line and the blank line must be skipped")
        XCTAssertTrue(openings[0].name.hasSuffix("#1"))
        XCTAssertTrue(openings[1].name.hasSuffix("#3"), "line numbers count the skipped line too")
    }

    func testLoadOpeningsReturnsEmptyForMissingFile() {
        XCTAssertTrue(EPD.loadOpenings(from: "/nonexistent/path/\(UUID().uuidString).epd").isEmpty)
    }

    func testSampleIsDeterministicForTheSameSeed() {
        let first = EPD.sample(Openings.standard, count: 5, seed: 42)
        let second = EPD.sample(Openings.standard, count: 5, seed: 42)
        XCTAssertEqual(first.map(\.name), second.map(\.name))
    }

    func testSampleDiffersAcrossSeeds() {
        let a = EPD.sample(Openings.standard, count: 5, seed: 1)
        let b = EPD.sample(Openings.standard, count: 5, seed: 2)
        XCTAssertNotEqual(a.map(\.name), b.map(\.name), "different seeds should (almost certainly) pick a different subset/order")
    }

    func testSampleCountIsRespected() {
        let sample = EPD.sample(Openings.standard, count: 4, seed: 7)
        XCTAssertEqual(sample.count, 4)
    }

    func testSampleWithoutReplacement() {
        let sample = EPD.sample(Openings.standard, count: Openings.standard.count - 1, seed: 3)
        XCTAssertEqual(Set(sample.map(\.name)).count, sample.count, "no opening should repeat")
    }

    func testSampleCountAtOrAboveTotalReturnsEverything() {
        let sample = EPD.sample(Openings.standard, count: Openings.standard.count + 5, seed: 1)
        XCTAssertEqual(sample.count, Openings.standard.count)
    }
}
