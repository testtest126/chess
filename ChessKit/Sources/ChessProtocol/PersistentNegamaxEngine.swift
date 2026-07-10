import Foundation
import ChessKit

/// A thread-safe flag a running search polls (every 1024 nodes) so it can be
/// interrupted from another thread — the mechanism behind stopping a ponder
/// search the moment the opponent's actual move arrives.
final class SearchStopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isStopRequested: Bool {
        lock.withLock { flag }
    }

    func requestStop() {
        lock.withLock { flag = true }
    }

    func reset() {
        lock.withLock { flag = false }
    }
}

/// A ``NegamaxEngine`` whose transposition table survives across `search`
/// calls, so consecutive searches of the same game start warm: entries stored
/// while thinking about (or pondering) one position prune the search of the
/// next. It also supports pondering — speculatively searching the expected
/// reply on the opponent's time — and interrupting a search in flight.
///
/// This is deliberately a separate, opt-in type: ``NegamaxEngine`` is a value
/// type whose fixed-limit searches are bit-for-bit reproducible (tests assert
/// exact node counts), and a warm table would break that. Use this class when
/// playing out a game, and the struct when you need determinism.
///
/// Thread safety: searches are serialized behind a lock, so the type is
/// `Sendable` despite the mutable table (`@unchecked` because the compiler
/// can't see the lock discipline). A caller on another thread can cut a
/// running search short with ``stopSearch()``; because the underlying search
/// only writes table entries for fully searched subtrees, an interrupted
/// search never leaves invalid entries behind.
public final class PersistentNegamaxEngine: ChessEngine, @unchecked Sendable {
    public var name: String { core.name }
    public var author: String { core.author }

    private let core: NegamaxEngine
    private let lock = NSLock()
    private let stopSignal = SearchStopSignal()
    /// The table carried between searches. Only touched while `lock` is held.
    private var table: [UInt64: Search.TTEntry] = [:]

    public init(
        name: String = "ChessKit-Negamax-TT",
        author: String = "ChessKit",
        book: OpeningBook? = nil
    ) {
        self.core = NegamaxEngine(name: name, author: author, book: book)
    }

    public func search(_ board: Board, limit: SearchLimit) -> SearchResult {
        lock.lock()
        defer { lock.unlock() }
        stopSignal.reset()
        return searchHoldingLock(board, limit: limit)
    }

    /// Pondering: while the opponent is on the move, predict their reply and
    /// search the position that would follow. Everything learned lands in the
    /// persistent table, so the real search after the opponent's actual move
    /// starts warm — fully so when the prediction was right, and still
    /// substantially so otherwise (the prediction pass itself searched every
    /// reply from the current position).
    ///
    /// Call ``stopSearch()`` from another thread to end pondering early; the
    /// search result is discarded either way. Returns the predicted reply
    /// (useful for tests/telemetry), or `nil` if the position is terminal.
    @discardableResult
    public func ponder(_ board: Board, limit: SearchLimit) -> Move? {
        lock.lock()
        defer { lock.unlock() }
        stopSignal.reset()

        // Pass 1: search the opponent's position to predict their move.
        guard let expected = searchHoldingLock(board, limit: limit).bestMove,
              let replied = board.making(expected) else { return nil }

        // Pass 2: search our expected follow-up position. Skipped when the
        // stop already arrived (deliberately no reset between the passes).
        if !stopSignal.isStopRequested {
            _ = searchHoldingLock(replied, limit: limit)
        }
        return expected
    }

    /// Asks the search currently in flight (if any) to stop at the next
    /// abort check. The interrupted call still returns its best fully
    /// searched move. Does not affect subsequent searches.
    public func stopSearch() {
        stopSignal.requestStop()
    }

    /// Forgets everything learned so far — call between unrelated games if
    /// reproducibility from a cold start matters. (Entries are keyed by
    /// position, so a stale table is never *wrong*, just memory spent on
    /// positions that will not recur.)
    public func clearTable() {
        lock.lock()
        defer { lock.unlock() }
        table = [:]
    }

    /// Number of positions currently held in the persistent table.
    public var tableEntryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return table.count
    }

    /// Runs one search seeded with the persistent table and stores the grown
    /// table back. `lock` must be held. The engine's reference is emptied for
    /// the duration of the search so the session mutates the dictionary's
    /// sole reference in place instead of triggering a copy-on-write clone.
    private func searchHoldingLock(_ board: Board, limit: SearchLimit) -> SearchResult {
        let session = Search(limit: limit, table: table, stop: stopSignal)
        table = [:]
        let result = core.search(board, limit: limit, session: session)
        table = session.table
        return result
    }
}
