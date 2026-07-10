import XCTest
import ChessKit
@testable import ChessProtocol

final class PersistentEngineTests: XCTestCase {

    // MARK: - Table persistence

    func testColdPersistentEngineMatchesFreshEngineExactly() {
        // With an empty table the class must behave bit-for-bit like the
        // deterministic struct — same move, same score, same node count.
        let board = Board(fen: "r1bq1rk1/pp2bppp/2n1pn2/3p4/2PP4/2N1PN2/PP2BPPP/R1BQ1RK1 w - - 0 8")!
        let fresh = NegamaxEngine().search(board, limit: SearchLimit(depth: 3))
        let warmable = PersistentNegamaxEngine().search(board, limit: SearchLimit(depth: 3))
        XCTAssertEqual(warmable.bestMove, fresh.bestMove)
        XCTAssertEqual(warmable.scoreCentipawns, fresh.scoreCentipawns)
        XCTAssertEqual(warmable.nodes, fresh.nodes)
    }

    func testTableReuseSameBestMoveFewerNodes() {
        // Searching the same position twice: the second run probes entries the
        // first one stored and should collapse to a fraction of the nodes
        // while still landing on the same move and score.
        let board = Board(fen: "r1bq1rk1/pp2bppp/2n1pn2/3p4/2PP4/2N1PN2/PP2BPPP/R1BQ1RK1 w - - 0 8")!
        let engine = PersistentNegamaxEngine()
        let limit = SearchLimit(depth: 4)

        let first = engine.search(board, limit: limit)
        XCTAssertGreaterThan(engine.tableEntryCount, 0, "the table should survive the search")
        let second = engine.search(board, limit: limit)

        print("TT reuse: first search \(first.nodes) nodes, repeat \(second.nodes) nodes")
        XCTAssertEqual(second.bestMove, first.bestMove)
        XCTAssertEqual(second.scoreCentipawns, first.scoreCentipawns)
        XCTAssertLessThan(second.nodes, first.nodes / 2, "a warm table should prune most of the repeat search")
    }

    func testTableCarriesAcrossConsecutiveGamePositions() throws {
        // Play the engine's move plus the predicted reply, then search the new
        // position: entries from the first search's subtrees should make the
        // follow-up search cheaper than a cold engine's search of it.
        let start = Board()
        let limit = SearchLimit(depth: 4)
        let engine = PersistentNegamaxEngine()

        let opening = engine.search(start, limit: limit)
        let move = try XCTUnwrap(opening.bestMove)
        let afterMove = try XCTUnwrap(start.making(move))
        let reply = try XCTUnwrap(engine.search(afterMove, limit: limit).bestMove)
        let nextPosition = try XCTUnwrap(afterMove.making(reply))

        let warm = engine.search(nextPosition, limit: limit)
        let cold = NegamaxEngine().search(nextPosition, limit: limit)

        print("TT across moves: warm \(warm.nodes) nodes vs cold \(cold.nodes) nodes")
        XCTAssertNotNil(warm.bestMove)
        XCTAssertTrue(nextPosition.isLegal(try XCTUnwrap(warm.bestMove)))
        XCTAssertLessThan(warm.nodes, cold.nodes, "carried-over entries should prune the next move's search")
    }

    func testClearTableRestoresColdBehavior() {
        let board = Board(fen: "r1bq1rk1/pp2bppp/2n1pn2/3p4/2PP4/2N1PN2/PP2BPPP/R1BQ1RK1 w - - 0 8")!
        let engine = PersistentNegamaxEngine()
        let limit = SearchLimit(depth: 3)

        let first = engine.search(board, limit: limit)
        engine.clearTable()
        XCTAssertEqual(engine.tableEntryCount, 0)
        let second = engine.search(board, limit: limit)
        XCTAssertEqual(second.nodes, first.nodes, "a cleared table means a fully cold, reproducible search")
    }

    func testPersistentTableKeepsMateScoresCorrectAcrossMoves() throws {
        // Mate in two: search it, play the winning line's first move and the
        // forced reply, then confirm the warm table still reports the right
        // (shorter) mate distance instead of a stale one.
        let board = Board(fen: "7k/8/8/8/8/8/R7/1R4K1 w - - 0 1")!
        let engine = PersistentNegamaxEngine()

        let first = engine.search(board, limit: SearchLimit(depth: 6))
        XCTAssertEqual(first.mateInPlies, 3)

        let afterFirst = try XCTUnwrap(board.making(try XCTUnwrap(first.bestMove)))
        let defense = try XCTUnwrap(engine.search(afterFirst, limit: SearchLimit(depth: 6)).bestMove)
        let beforeMate = try XCTUnwrap(afterFirst.making(defense))

        let final = engine.search(beforeMate, limit: SearchLimit(depth: 6))
        XCTAssertEqual(final.mateInPlies, 1)
        let mate = try XCTUnwrap(final.bestMove)
        XCTAssertTrue(beforeMate.making(mate)!.legalMoves().isEmpty, "the found move should deliver mate")
    }

    // MARK: - Bounded table

    func testTableStaysWithinConfiguredCapAcrossAGame() throws {
        // Walk a short game, giving each search a fixed node budget so it
        // stores far more entries than the cap. A bounded engine must never
        // exceed its cap; an unbounded one following the same line proves the
        // walk really overflows it, so the bound is exercised, not vacuous.
        let cap = 200
        let bounded = PersistentNegamaxEngine(maxTableEntries: cap)
        let unbounded = PersistentNegamaxEngine(maxTableEntries: .max)
        let limit = SearchLimit(depth: 20, maxNodes: 3_000)
        var board = Board()

        for _ in 0..<3 {
            let result = bounded.search(board, limit: limit)
            _ = unbounded.search(board, limit: limit)
            XCTAssertLessThanOrEqual(bounded.tableEntryCount, cap,
                                     "bounded engine must never exceed its cap")
            guard let move = result.bestMove, let next = board.making(move) else { break }
            board = next
        }

        XCTAssertGreaterThan(unbounded.tableEntryCount, cap,
                             "sanity: the same walk overflows the cap, so the bound was real")
        XCTAssertGreaterThan(bounded.tableEntryCount, 0)
    }

    func testBoundedEnginePlaysALegalGameUnderConstantEviction() throws {
        // A table so small it evicts after every move must still drive a
        // coherent game: each search seeds from the previous move's pruned
        // table, yet every move it returns is legal and the bound always holds.
        let cap = 300
        let engine = PersistentNegamaxEngine(maxTableEntries: cap)
        let limit = SearchLimit(depth: 20, maxNodes: 3_000)
        var game = Game()

        for _ in 0..<5 {
            guard !game.isOver else { break }
            let move = try XCTUnwrap(engine.search(game.board, limit: limit).bestMove)
            XCTAssertTrue(game.board.isLegal(move))
            XCTAssertLessThanOrEqual(engine.tableEntryCount, cap,
                                     "the bound must hold after every move")
            _ = try game.play(move)
        }

        XCTAssertGreaterThan(game.moveCount, 0)
    }

    func testEvictionKeepsTheJustSearchedPositionWarm() throws {
        // Overflow a modest cap over several moves, then re-search the most
        // recent position: its current-generation entries are evicted last, so
        // the repeat rides a warm table — far cheaper than a cold search of it.
        let cap = 1_500
        let engine = PersistentNegamaxEngine(maxTableEntries: cap)
        var board = Board()
        var recent = board

        for _ in 0..<5 {
            recent = board
            guard let move = engine.search(board, limit: SearchLimit(depth: 3)).bestMove,
                  let next = board.making(move) else { break }
            board = next
        }

        let warm = engine.search(recent, limit: SearchLimit(depth: 3))
        let cold = NegamaxEngine().search(recent, limit: SearchLimit(depth: 3))
        XCTAssertLessThan(warm.nodes, cold.nodes,
                          "the just-searched position must stay warm despite eviction")
        XCTAssertLessThanOrEqual(engine.tableEntryCount, cap)
    }

    // MARK: - Pondering

    func testPonderReturnsLegalPredictionAndWarmsTable() throws {
        let engine = PersistentNegamaxEngine()
        let board = Board()

        let predicted = try XCTUnwrap(engine.ponder(board, limit: SearchLimit(depth: 3)))
        XCTAssertTrue(board.isLegal(predicted))
        XCTAssertGreaterThan(engine.tableEntryCount, 0)

        // A real search after pondering the very position it predicted
        // should ride the warm table.
        let pondered = try XCTUnwrap(board.making(predicted))
        let cold = NegamaxEngine().search(pondered, limit: SearchLimit(depth: 3))
        let warm = engine.search(pondered, limit: SearchLimit(depth: 3))
        print("ponder hit: warm \(warm.nodes) nodes vs cold \(cold.nodes) nodes")
        XCTAssertLessThan(warm.nodes, cold.nodes)
    }

    func testPonderOnTerminalPositionReturnsNil() {
        // Fool's mate: no legal moves, nothing to ponder, no crash.
        let board = Board(fen: "rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3")!
        let engine = PersistentNegamaxEngine()
        XCTAssertNil(engine.ponder(board, limit: SearchLimit(depth: 2)))
    }

    func testStopSearchInterruptsPondering() async {
        // Unstopped, this ponder would run two ~8-second passes. Hammering
        // stopSearch from another task must bring it home almost immediately.
        let engine = PersistentNegamaxEngine()
        let board = Board(fen: "r1bq1rk1/pp2bppp/2n1pn2/3p4/2PP4/2N1PN2/PP2BPPP/R1BQ1RK1 w - - 0 8")!

        let clock = ContinuousClock()
        let started = clock.now
        let ponder = Task.detached {
            engine.ponder(board, limit: SearchLimit(depth: 64, moveTime: 8))
        }
        let stopper = Task.detached {
            while !Task.isCancelled {
                engine.stopSearch()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        _ = await ponder.value
        stopper.cancel()

        let elapsed = clock.now - started
        XCTAssertLessThan(elapsed, .seconds(6), "a stopped ponder must not run out its full time budget")
    }

    func testPonderingWhileOpponentThinksDoesNotCorruptPlay() async throws {
        // Simulate the app's flow: the persistent engine plays one side and
        // ponders (concurrently, on a background task) while the "human" —
        // a fresh deterministic engine — picks a reply. Every move the
        // persistent engine produces must be legal in the position it was
        // asked about, and the game record must stay coherent throughout.
        let engine = PersistentNegamaxEngine()
        let human = NegamaxEngine()
        var game = Game()

        for _ in 0..<4 {
            guard !game.isOver else { break }

            // Engine's move on its own time.
            let position = game.board
            let move = try XCTUnwrap(engine.search(position, limit: SearchLimit(depth: 3)).bestMove)
            XCTAssertTrue(position.isLegal(move))
            _ = try game.play(move)
            guard !game.isOver else { break }

            // Human thinks; engine ponders concurrently on the same position.
            let humanPosition = game.board
            let ponder = Task.detached {
                engine.ponder(humanPosition, limit: SearchLimit(depth: 3))
            }
            let reply = try XCTUnwrap(human.search(humanPosition, limit: SearchLimit(depth: 2)).bestMove)
            engine.stopSearch()
            _ = await ponder.value

            XCTAssertTrue(humanPosition.isLegal(reply))
            _ = try game.play(reply)
        }

        XCTAssertGreaterThanOrEqual(game.moveCount, 8, "four full move pairs should have been played")
    }
}
