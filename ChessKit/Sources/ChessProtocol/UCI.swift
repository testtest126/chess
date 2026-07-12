import Foundation
import ChessKit

/// A minimal UCI (Universal Chess Interface) adapter around a ``ChessEngine``.
///
/// It maintains the current position from `position` commands and answers `go`
/// with a search. The core is ``process(_:)``, which maps one input line to zero
/// or more response lines — pure and synchronous, so it can be unit-tested without
/// wiring up real stdin/stdout. ``run()`` drives it over standard streams.
public final class UCIEngine {
    private let engine: ChessEngine
    private var board: Board
    /// Set once a `quit` command has been processed.
    public private(set) var shouldQuit = false

    /// Default search depth used when `go` specifies no limit.
    public var defaultDepth: Int

    public init(engine: ChessEngine, defaultDepth: Int = 4) {
        self.engine = engine
        self.board = Board()
        self.defaultDepth = defaultDepth
    }

    /// The position the adapter would currently search. Exposed for testing.
    public var currentBoard: Board { board }

    /// Processes a single UCI input line and returns the response lines to emit.
    public func process(_ line: String) -> [String] {
        let tokens = line.split(separator: " ").map(String.init)
        guard let command = tokens.first else { return [] }
        let args = Array(tokens.dropFirst())

        switch command {
        case "uci":
            return [
                "id name \(engine.name)",
                "id author \(engine.author)",
                "uciok",
            ]
        case "isready":
            return ["readyok"]
        case "ucinewgame":
            board = Board()
            return []
        case "position":
            applyPosition(args)
            return []
        case "go":
            return runGo(args)
        case "quit":
            shouldQuit = true
            return []
        default:
            // Unknown/ignored commands (debug, setoption, stop, ponderhit, …).
            return []
        }
    }

    /// Reads UCI commands from standard input and writes responses to standard
    /// output until `quit`. Blocks the calling thread.
    public func run() {
        while !shouldQuit, let line = readLine(strippingNewline: true) {
            for response in process(line) {
                print(response)
            }
        }
    }

    // MARK: - Command handlers

    /// Parses `position [startpos | fen <fen fields>] [moves <uci>...]`.
    private func applyPosition(_ args: [String]) {
        var index = 0
        var newBoard: Board?

        if args.first == "startpos" {
            newBoard = Board()
            index = 1
        } else if args.first == "fen" {
            // The FEN runs until the "moves" keyword, capped at six fields.
            // Stopping at "moves" is what lets a short FEN (Board accepts 4–5
            // fields, defaulting the clocks) keep its trailing moves instead of
            // swallowing the "moves" token and the moves into the FEN string.
            let fenFields = Array(args.dropFirst().prefix { $0 != "moves" }.prefix(6))
            newBoard = Board(fen: fenFields.joined(separator: " "))
            index = 1 + fenFields.count
        }

        guard var position = newBoard else { return } // malformed; leave board untouched

        if index < args.count, args[index] == "moves" {
            for uci in args[(index + 1)...] {
                guard let move = Move(uci: uci), let next = position.making(move) else { break }
                position = next
            }
        }
        board = position
    }

    /// Parses the subset of `go` we support (`depth`, `nodes`, `movetime`),
    /// searches, and returns an `info` line followed by `bestmove`.
    private func runGo(_ args: [String]) -> [String] {
        var depth = defaultDepth
        var maxNodes: Int?
        var moveTime: TimeInterval?

        var i = 0
        while i < args.count {
            switch args[i] {
            case "depth":
                if i + 1 < args.count, let d = Int(args[i + 1]) { depth = d; i += 1 }
            case "nodes":
                if i + 1 < args.count, let n = Int(args[i + 1]) { maxNodes = n; i += 1 }
            case "movetime":
                // UCI movetime is in milliseconds.
                if i + 1 < args.count, let ms = Int(args[i + 1]) {
                    moveTime = TimeInterval(ms) / 1000
                    // A time-managed search deepens as far as the budget
                    // allows; the explicit depth (if any) stays the ceiling.
                    if !args.contains("depth") { depth = 64 }
                    i += 1
                }
            default:
                break
            }
            i += 1
        }

        let result = engine.search(board, limit: SearchLimit(depth: depth, maxNodes: maxNodes, moveTime: moveTime))

        var lines: [String] = []
        lines.append(infoLine(for: result))
        lines.append("bestmove \(result.bestMove?.uci ?? "(none)")")
        return lines
    }

    /// Formats a UCI `info` line from a search result.
    private func infoLine(for result: SearchResult) -> String {
        let score: String
        if let plies = result.mateInPlies {
            score = "mate \(Self.mateMoves(fromPlies: plies))"
        } else {
            score = "cp \(result.scoreCentipawns)"
        }
        return "info depth \(result.depth) score \(score) nodes \(result.nodes)"
    }

    /// Converts plies-to-mate into the whole-move count UCI reports, keeping sign.
    static func mateMoves(fromPlies plies: Int) -> Int {
        plies >= 0 ? (plies + 1) / 2 : -((-plies + 1) / 2)
    }
}
