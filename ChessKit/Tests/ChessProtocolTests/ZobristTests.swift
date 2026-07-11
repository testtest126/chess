import XCTest
@testable import ChessKit
@testable import ChessProtocol

final class ZobristTests: XCTestCase {
    func testSamePositionProducesSameKey() {
        let board = Board()
        let key1 = Zobrist.key(for: board)
        let key2 = Zobrist.key(for: board)
        XCTAssertEqual(key1, key2)
    }

    func testDifferentPositionsProduceDifferentKeys() {
        let start = Board()
        var afterE4 = start
        afterE4.apply(Move(uci: "e2e4")!)

        XCTAssertNotEqual(Zobrist.key(for: start), Zobrist.key(for: afterE4))
    }

    func testSideToMoveAffectsKey() {
        // Same piece placement, different side to move.
        let whiteToMove = Board(fen: "4k3/8/8/8/8/8/8/4K3 w - - 0 1")!
        let blackToMove = Board(fen: "4k3/8/8/8/8/8/8/4K3 b - - 0 1")!
        XCTAssertNotEqual(Zobrist.key(for: whiteToMove), Zobrist.key(for: blackToMove))
    }

    func testCastlingRightsAffectKey() {
        let withCastling = Board(fen: "r3k2r/pppppppp/8/8/8/8/PPPPPPPP/R3K2R w KQkq - 0 1")!
        let noCastling = Board(fen: "r3k2r/pppppppp/8/8/8/8/PPPPPPPP/R3K2R w - - 0 1")!
        XCTAssertNotEqual(Zobrist.key(for: withCastling), Zobrist.key(for: noCastling))
    }

    func testEnPassantAffectsKey() {
        let withEP = Board(fen: "rnbqkbnr/pppp1ppp/8/4pP2/8/8/PPPPP1PP/RNBQKBNR w KQkq e6 0 3")!
        let noEP = Board(fen: "rnbqkbnr/pppp1ppp/8/4pP2/8/8/PPPPP1PP/RNBQKBNR w KQkq - 0 3")!
        XCTAssertNotEqual(Zobrist.key(for: withEP), Zobrist.key(for: noEP))
    }

    func testTransposedPositionsProduceSameKey() {
        // 1. e4 d5 and 1. d5 e4... well, those aren't both legal. Let's use
        // positions that transpose: 1. Nf3 Nf6 2. Ng1 Ng8 = starting position.
        var board = Board()
        board.apply(Move(uci: "g1f3")!)
        board.apply(Move(uci: "g8f6")!)
        board.apply(Move(uci: "f3g1")!)
        board.apply(Move(uci: "f6g8")!)
        // Back to starting position piece layout, but clocks differ.
        // The key should match because Zobrist only hashes pieces, castling,
        // EP, and side — not move clocks.
        XCTAssertEqual(Zobrist.key(for: board), Zobrist.key(for: Board()))
    }

    func testKeyIsDeterministicAcrossInstances() {
        // Zobrist uses a fixed-seed PRNG, so keys are stable across runs.
        let board = Board(fen: "r1bqkbnr/pppppppp/2n5/4P3/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0 2")!
        let key1 = Zobrist.key(for: board)
        let key2 = Zobrist.key(for: board)
        XCTAssertEqual(key1, key2)
        XCTAssertNotEqual(key1, 0)
    }

    func testAllPieceTypesContributeToKey() {
        // A board with just two kings vs one with an extra piece should differ.
        let bare = Board(fen: "4k3/8/8/8/8/8/8/4K3 w - - 0 1")!
        let withQueen = Board(fen: "4k3/8/8/8/8/8/8/3QK3 w - - 0 1")!
        let withRook = Board(fen: "4k3/8/8/8/8/8/8/3RK3 w - - 0 1")!
        let withBishop = Board(fen: "4k3/8/8/8/8/8/8/3BK3 w - - 0 1")!
        let withKnight = Board(fen: "4k3/8/8/8/8/8/8/3NK3 w - - 0 1")!
        let withPawn = Board(fen: "4k3/8/8/8/8/8/3P4/4K3 w - - 0 1")!

        let keys = Set([
            Zobrist.key(for: bare),
            Zobrist.key(for: withQueen),
            Zobrist.key(for: withRook),
            Zobrist.key(for: withBishop),
            Zobrist.key(for: withKnight),
            Zobrist.key(for: withPawn),
        ])
        XCTAssertEqual(keys.count, 6, "each piece type should produce a unique key")
    }
}
