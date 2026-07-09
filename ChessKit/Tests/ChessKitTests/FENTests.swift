import XCTest
@testable import ChessKit

final class FENTests: XCTestCase {

    func testStartingPositionRoundTrip() {
        let board = Board()
        XCTAssertEqual(board.fen, Board.startingFEN)
    }

    func testRoundTripPreservesAllFields() {
        let fens = [
            "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
            "rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2",
            "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
            "4k3/8/8/8/8/8/8/4K2R b K - 5 39",
        ]
        for fen in fens {
            let board = Board(fen: fen)
            XCTAssertNotNil(board, "failed to parse \(fen)")
            XCTAssertEqual(board?.fen, fen, "round-trip mismatch for \(fen)")
        }
    }

    func testParsesFieldsCorrectly() {
        let board = Board(fen: "rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2")!
        XCTAssertEqual(board.sideToMove, .white)
        XCTAssertEqual(board.castlingRights, .all)
        XCTAssertEqual(board.enPassantSquare, Sq.parse("c6"))
        XCTAssertEqual(board.halfmoveClock, 0)
        XCTAssertEqual(board.fullmoveNumber, 2)
        XCTAssertEqual(board[Sq.parse("e4")!], Piece(color: .white, kind: .pawn))
        XCTAssertEqual(board[Sq.parse("c5")!], Piece(color: .black, kind: .pawn))
    }

    func testRejectsMalformedFEN() {
        let bad = [
            "",                                              // empty
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP w KQkq - 0 1", // only 7 ranks
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR x KQkq - 0 1", // bad side
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w XYZ - 0 1",  // bad castling
            "rnbqkbnr/ppppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", // rank too long
        ]
        for fen in bad {
            XCTAssertNil(Board(fen: fen), "should reject \(fen)")
        }
    }

    func testSquareHelpers() {
        XCTAssertEqual(Sq.parse("a1"), 0)
        XCTAssertEqual(Sq.parse("h8"), 63)
        XCTAssertEqual(Sq.name(0), "a1")
        XCTAssertEqual(Sq.name(63), "h8")
        XCTAssertTrue(Sq.isLight(Sq.parse("h1")!))   // h1 is a light square
        XCTAssertFalse(Sq.isLight(Sq.parse("a1")!))  // a1 is dark
        XCTAssertNil(Sq.parse("i9"))
    }
}
