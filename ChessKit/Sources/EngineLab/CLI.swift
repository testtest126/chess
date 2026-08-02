import ChessProtocol
import Foundation

/// Command-line front end for the measurement harness. All parsing, dispatch,
/// and formatting live here (not in the executable's `main`) so they are
/// exercised by `swift test`; the executable is a one-line shim.
public enum CLI {
    public static let usage = """
    engine-lab — ChessKit-Negamax measurement harness

    USAGE:
      engine-lab bench   [--nodes N | --depth D]
      engine-lab match   [--depth-a D] [--depth-b D] [--nodes-a N] [--nodes-b N]
                         [--games G] [--max-plies P]
      engine-lab abtest  [--depth D] [--baseline-depth D] [--candidate-depth D]
                         [--elo0 E0] [--elo1 E1] [--alpha A] [--beta B]
                         [--draw-prob P] [--games G] [--max-plies P]
                         [--epd PATH [--sample N [--seed S]]]

    bench   Search the fixed 20-position suite under one reproducible limit and
            print total nodes, nodes/sec, and a behavioral signature. Default
            limit: a \(Bench.defaultNodeBudget)-node budget per position.

    match   Play a self-play match (each opening twice, colors swapped) and
            report W/D/L, score %, and Elo(A - B) with a 95% margin. Configs A
            and B default to depth 4. All limits are fixed nodes/depth, so runs
            are reproducible.

    abtest  Play a candidate evaluator (MaterialOnlyEvaluator, by default)
            against a fixed baseline (DefaultEvaluator) across many openings,
            both colors, checking an SPRT after every game so a confident
            result can stop before the full schedule. Reports W/D/L, score %,
            Elo with a 95% margin, and the SPRT verdict. `--epd` points at an
            EPD opening suite (e.g. from testtest126/books) instead of the
            built-in set; `--sample N` (with `--seed S`) deterministically
            samples N positions from it.
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
        case "abtest":
            return runABTest(args)
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
        depthKey: String, nodesKey: String, defaultDepth: Int, options: [String: String],
        label: String? = nil, evaluator: any PositionEvaluator = DefaultEvaluator()
    ) -> EngineConfig {
        if let nodes = options[nodesKey].flatMap(Int.init) {
            return EngineConfig(label: label ?? "nodes-\(nodes)", limit: Bench.nodeLimit(nodes), evaluator: evaluator)
        }
        let depth = options[depthKey].flatMap(Int.init) ?? defaultDepth
        return EngineConfig(label: label ?? "depth-\(depth)", limit: SearchLimit(depth: depth), evaluator: evaluator)
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

    // MARK: - abtest

    static func runABTest(_ args: [String]) -> Int32 {
        let options = parseOptions(args)
        let sharedDepth = options["depth"].flatMap(Int.init) ?? 3
        let baseline = config(
            depthKey: "baseline-depth", nodesKey: "baseline-nodes", defaultDepth: sharedDepth, options: options,
            label: "baseline (DefaultEvaluator)", evaluator: DefaultEvaluator()
        )
        let candidate = config(
            depthKey: "candidate-depth", nodesKey: "candidate-nodes", defaultDepth: sharedDepth, options: options,
            label: "candidate (MaterialOnlyEvaluator)", evaluator: MaterialOnlyEvaluator()
        )
        let maxPlies = options["max-plies"].flatMap(Int.init) ?? SelfPlay.defaultMaxPlies
        let maxGames = options["games"].flatMap(Int.init)

        var openings = Openings.standard
        if let epdPath = options["epd"] {
            let loaded = EPD.loadOpenings(from: epdPath)
            if loaded.isEmpty {
                print("engine-lab: no usable positions loaded from '\(epdPath)'")
                return 1
            }
            if let sampleCount = options["sample"].flatMap(Int.init) {
                let seed = options["seed"].flatMap(UInt64.init) ?? 1
                openings = EPD.sample(loaded, count: sampleCount, seed: seed)
            } else {
                openings = loaded
            }
        }

        let sprtParameters = SPRT.Parameters(
            elo0: options["elo0"].flatMap(Double.init) ?? 0,
            elo1: options["elo1"].flatMap(Double.init) ?? 10,
            alpha: options["alpha"].flatMap(Double.init) ?? 0.05,
            beta: options["beta"].flatMap(Double.init) ?? 0.05,
            assumedDrawProbability: options["draw-prob"].flatMap(Double.init) ?? 0.5
        )
        guard sprtParameters.isValid else {
            print(
                "engine-lab: --draw-prob \(sprtParameters.assumedDrawProbability) is too large for "
                    + "elo0=\(sprtParameters.elo0)/elo1=\(sprtParameters.elo1) "
                    + "(implied win or loss probability would go negative)"
            )
            return 1
        }

        let abConfig = ABTestConfig(
            baseline: baseline, candidate: candidate, openings: openings,
            maxPlies: maxPlies, sprt: sprtParameters, maxGames: maxGames
        )
        let result = ABTest.run(abConfig)
        print(format(result))
        return 0
    }

    static func format(_ result: ABTestResult) -> String {
        var lines: [String] = []
        lines.append("A/B eval measurement")
        lines.append("candidate: \(result.candidateLabel)    baseline: \(result.baselineLabel)")
        let stoppedNote = result.sprtDecidedAtGame.map { _ in " — SPRT decided here" } ?? ""
        lines.append("games: \(result.gamesPlayed)\(stoppedNote)")
        lines.append(
            "candidate results: +\(result.wins) =\(result.draws) -\(result.losses)   "
                + "score: \(percent(result.scoreCandidate))"
        )
        lines.append(
            "Elo(candidate - baseline): \(signedString(Int(result.eloDelta.rounded()))) "
                + "± \(Int(result.eloMargin.rounded()))  (95%)"
        )
        lines.append(
            "SPRT: llr \(String(format: "%.2f", result.sprt.llr))"
                + " (bounds \(String(format: "%.2f", result.sprt.lowerBound))"
                + " .. \(String(format: "%.2f", result.sprt.upperBound)))"
                + " -> \(result.sprt.decision.rawValue)"
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
