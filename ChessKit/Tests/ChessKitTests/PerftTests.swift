import XCTest
@testable import ChessKit

/// Perft (performance test) counts leaf nodes of the legal-move tree to a fixed
/// depth. Matching the well-known reference counts exercises every rule —
/// pins, en passant, castling legality, promotions, discovered checks — so a
/// single mismatch is a strong signal that move generation is wrong.
final class PerftTests: XCTestCase {
    /// Uses `@testable` access to `apply` so nodes don't pay for the redundant
    /// legality re-check that `making(_:)` performs.
    private func perft(_ board: Board, depth: Int) -> Int {
        if depth == 0 { return 1 }
        let moves = board.legalMoves()
        if depth == 1 { return moves.count }
        var total = 0
        for move in moves {
            var next = board
            next.apply(move)
            total += perft(next, depth: depth - 1)
        }
        return total
    }

    func testStartingPositionPerft() {
        let board = Board()
        XCTAssertEqual(perft(board, depth: 1), 20)
        XCTAssertEqual(perft(board, depth: 2), 400)
        XCTAssertEqual(perft(board, depth: 3), 8_902)
        XCTAssertEqual(perft(board, depth: 4), 197_281)
    }

    /// "Kiwipete" — a dense middlegame that catches castling and en-passant bugs.
    func testKiwipetePerft() {
        let board = Board(fen: "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1")!
        XCTAssertEqual(perft(board, depth: 1), 48)
        XCTAssertEqual(perft(board, depth: 2), 2_039)
        XCTAssertEqual(perft(board, depth: 3), 97_862)
    }

    /// Position 3 — sparse, heavy on rook/pawn edge cases and en passant.
    func testPosition3Perft() {
        let board = Board(fen: "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1")!
        XCTAssertEqual(perft(board, depth: 1), 14)
        XCTAssertEqual(perft(board, depth: 2), 191)
        XCTAssertEqual(perft(board, depth: 3), 2_812)
        XCTAssertEqual(perft(board, depth: 4), 43_238)
    }

    /// Position 4 — promotions and pins around a castled king.
    func testPosition4Perft() {
        let board = Board(fen: "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1")!
        XCTAssertEqual(perft(board, depth: 1), 6)
        XCTAssertEqual(perft(board, depth: 2), 264)
        XCTAssertEqual(perft(board, depth: 3), 9_467)
    }

    /// Position 5 — tricky underpromotion and check interactions.
    func testPosition5Perft() {
        let board = Board(fen: "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8")!
        XCTAssertEqual(perft(board, depth: 1), 44)
        XCTAssertEqual(perft(board, depth: 2), 1_486)
        XCTAssertEqual(perft(board, depth: 3), 62_379)
    }
}
