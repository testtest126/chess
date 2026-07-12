import ChessProtocol
import Foundation

/// Command-line front end for the measurement harness. All parsing, dispatch,
/// and formatting live here (not in the executable's `main`) so they are
/// exercised by `swift test`; the executable is a one-line shim.
public enum CLI {
    public static let usage = """
    engine-lab — ChessKit-Negamax measurement harness

    USAGE:
      engine-lab bench  [--nodes N | --depth D]
      engine-lab match  [--depth-a D] [--depth-b D] [--nodes-a N] [--nodes-b N]
                        [--games G] [--max-plies P]

    bench   Search the fixed 20-position suite under one reproducible limit and
            print total nodes, nodes/sec, and a behavioral signature. Default
            limit: a \(Bench.defaultNodeBudget)-node budget per position.

    match   Play a self-play match (each opening twice, colors swapped) and
            report W/D/L, score %, and Elo(A - B) with a 95% margin. Configs A
            and B default to depth 4. All limits are fixed nodes/depth, so runs
            are reproducible.
    """

    /// Entry point. `arguments` is the full `CommandLine.arguments` (with the
    /// program name at index 0). Returns a process exit code.
    public static func run(_ arguments: [String]) -> Int32 {
        var args = Array(arguments.dropFirst())
        guard let subcommand = args.first else {
            print(usage)
            return 2
        }
        args.removeFirst()

        switch subcommand {
        case "bench":
            return runBench(args)
        case "match":
            return runMatch(args)
        case "-h", "--help", "help":
            print(usage)
            return 0
        default:
            print("engine-lab: unknown subcommand '\(subcommand)'\n")
            print(usage)
            return 2
        }
    }

    // MARK: - bench

    static func runBench(_ args: [String]) -> Int32 {
        let options = parseOptions(args)
        let depth = options["depth"].flatMap(Int.init)
        let nodes = options["nodes"].flatMap(Int.init)

        let limit: SearchLimit
        switch (depth, nodes) {
        case (let d?, let n?):
            limit = SearchLimit(depth: d, maxNodes: n)
        case (let d?, nil):
            limit = SearchLimit(depth: d)
        case (nil, let n?):
            limit = Bench.nodeLimit(n)
        case (nil, nil):
            limit = Bench.nodeLimit(Bench.defaultNodeBudget)
        }

        let result = Bench.run(limit: limit)
        print(format(result))
        return 0
    }

    static func format(_ result: BenchResult) -> String {
        var lines: [String] = []
        lines.append("ChessKit-Negamax bench")
        lines.append("limit: \(describe(result.limit))")
        lines.append("")
        for row in result.perPosition {
            let name = row.name.padding(toLength: 18, withPad: " ", startingAt: 0)
            let score = signedString(row.scoreCentipawns)
            lines.append(
                "  \(name) depth \(pad(row.depth, 3))  "
                    + "score \(pad(score, 8))  nodes \(pad(row.nodes, 10))  \(row.bestMove)"
            )
        }
        lines.append("")
        lines.append(
            "positions: \(result.perPosition.count)   "
                + "total nodes: \(result.totalNodes)   "
                + "time: \(seconds(result.elapsedSeconds))   "
                + "speed: \(mnps(result.nodesPerSecond))"
        )
        lines.append("signature: \(hex(result.signature))")
        return lines.joined(separator: "\n")
    }

    // MARK: - match

    static func runMatch(_ args: [String]) -> Int32 {
        let options = parseOptions(args)
        let a = config(depthKey: "depth-a", nodesKey: "nodes-a", defaultDepth: 4, options: options)
        let b = config(depthKey: "depth-b", nodesKey: "nodes-b", defaultDepth: 4, options: options)
        let maxPlies = options["max-plies"].flatMap(Int.init) ?? SelfPlay.defaultMaxPlies

        // `--games G` caps how many openings are used (each played twice).
        var openings = Openings.standard
        if let games = options["games"].flatMap(Int.init), games > 0 {
            let pairs = max(1, (games + 1) / 2)
            openings = Array(openings.prefix(pairs))
        }

        let result = SelfPlay.playMatch(a: a, b: b, openings: openings, maxPlies: maxPlies)
        print(format(result, openings: openings.count))
        return 0
    }

    static func config(
        depthKey: String, nodesKey: String, defaultDepth: Int, options: [String: String]
    ) -> EngineConfig {
        if let nodes = options[nodesKey].flatMap(Int.init) {
            return EngineConfig(label: "nodes-\(nodes)", limit: Bench.nodeLimit(nodes))
        }
        let depth = options[depthKey].flatMap(Int.init) ?? defaultDepth
        return EngineConfig(label: "depth-\(depth)", limit: SearchLimit(depth: depth))
    }

    static func format(_ result: MatchResult, openings: Int) -> String {
        var lines: [String] = []
        lines.append("Self-play match")
        lines.append("A: \(result.aLabel)    B: \(result.bLabel)")
        lines.append("games: \(result.games)  (\(openings) openings × 2 colors)")
        lines.append(
            "A results: +\(result.wins) =\(result.draws) -\(result.losses)   "
                + "score: \(percent(result.scoreA))"
        )
        lines.append(
            "Elo(A - B): \(signedString(Int(result.eloDelta.rounded()))) "
                + "± \(Int(result.eloMargin.rounded()))  (95%)"
        )
        return lines.joined(separator: "\n")
    }

    // MARK: - Option parsing & formatting helpers

    /// Reads `--key value` pairs into a dictionary (keys without the dashes).
    static func parseOptions(_ args: [String]) -> [String: String] {
        var options: [String: String] = [:]
        var index = 0
        while index < args.count {
            let token = args[index]
            if token.hasPrefix("--"), index + 1 < args.count {
                options[String(token.dropFirst(2))] = args[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
        return options
    }

    static func describe(_ limit: SearchLimit) -> String {
        if let nodes = limit.maxNodes {
            return "nodes<=\(nodes) (depth ceiling \(limit.depth))"
        }
        return "depth \(limit.depth)"
    }

    static func signedString(_ value: Int) -> String {
        value >= 0 ? "+\(value)" : "\(value)"
    }

    static func pad(_ value: Int, _ width: Int) -> String {
        pad("\(value)", width)
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }

    static func hex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16)
    }

    static func seconds(_ value: Double) -> String {
        String(format: "%.2fs", value)
    }

    static func mnps(_ nodesPerSecond: Double) -> String {
        String(format: "%.2f Mnps", nodesPerSecond / 1_000_000)
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.1f%%", fraction * 100)
    }
}
