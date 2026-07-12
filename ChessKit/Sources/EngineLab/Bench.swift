import ChessKit
import ChessProtocol
import Foundation

/// A 64-bit rolling checksum. Deterministic and order-sensitive, so it detects
/// any change in the per-position results (nodes, depth, score, best move) even
/// when — as under a hard node cap — the total node count is pinned to the
/// budget and would not move on its own.
struct Signature {
    private(set) var value: UInt64 = 0xCBF2_9CE4_8422_2325 // FNV offset basis

    mutating func fold(_ v: UInt64) {
        value ^= v
        value = value &* 0x9E37_79B9_7F4A_7C15 // fibonacci hashing multiplier
        value ^= value >> 29
    }

    mutating func fold(_ v: Int) {
        fold(UInt64(bitPattern: Int64(v)))
    }
}

/// Per-position bench measurement.
public struct BenchPositionResult: Sendable {
    public let name: String
    public let nodes: Int
    public let depth: Int
    public let scoreCentipawns: Int
    public let bestMove: String
}

/// The result of a whole bench run.
public struct BenchResult: Sendable {
    public let limit: SearchLimit
    public let perPosition: [BenchPositionResult]
    public let totalNodes: Int
    public let elapsedSeconds: Double
    /// Behavioral fingerprint of the run — stable across runs, moves only when
    /// search behavior changes. The determinism regression guard.
    public let signature: UInt64

    public var nodesPerSecond: Double {
        elapsedSeconds > 0 ? Double(totalNodes) / elapsedSeconds : 0
    }
}

/// Fixed-workload bench: search each suite position under one reproducible
/// limit and summarize. Reproducibility comes from fixed node/depth limits (no
/// wall-clock) and no opening book, so `signature` and `totalNodes` are
/// identical on every machine and every run.
public enum Bench {
    /// A fixed per-position node budget for the executable's default run.
    /// Sized so the whole suite finishes in ~20s in a release build while still
    /// reaching non-trivial depths — the engine is deliberately simple and only
    /// searches a few hundred thousand nodes/sec.
    public static let defaultNodeBudget = 200_000

    /// A limit that caps each search at `nodes` visited (with a high depth
    /// ceiling so the node budget, not depth, is the binding constraint).
    public static func nodeLimit(_ nodes: Int) -> SearchLimit {
        SearchLimit(depth: 64, maxNodes: nodes)
    }

    public static func run(
        limit: SearchLimit = Bench.nodeLimit(defaultNodeBudget),
        positions: [BenchPosition] = BenchSuite.positions
    ) -> BenchResult {
        // A fresh, book-less engine: the deterministic configuration.
        let engine = NegamaxEngine()
        var perPosition: [BenchPositionResult] = []
        perPosition.reserveCapacity(positions.count)
        var totalNodes = 0
        var signature = Signature()

        let clock = ContinuousClock()
        let start = clock.now
        for (index, position) in positions.enumerated() {
            let board = parseFEN(position.fen)
            let result = engine.search(board, limit: limit)
            totalNodes += result.nodes

            // Fold every observable of the search into the signature, keyed by
            // position index so a reordering is also detected.
            signature.fold(index)
            signature.fold(result.nodes)
            signature.fold(result.depth)
            signature.fold(result.scoreCentipawns)
            signature.fold(moveCode(result.bestMove))

            perPosition.append(BenchPositionResult(
                name: position.name,
                nodes: result.nodes,
                depth: result.depth,
                scoreCentipawns: result.scoreCentipawns,
                bestMove: result.bestMove?.uci ?? "(none)"
            ))
        }
        let elapsed = clock.now - start

        return BenchResult(
            limit: limit,
            perPosition: perPosition,
            totalNodes: totalNodes,
            elapsedSeconds: elapsed.seconds,
            signature: signature.value
        )
    }

    /// Encodes a move as a small integer for the signature (0 = no move).
    private static func moveCode(_ move: Move?) -> Int {
        guard let move else { return 0 }
        let promo = move.promotion.map { $0.rawValueForSignature } ?? 0
        return 1 + move.from * 64 * 8 + move.to * 8 + promo
    }
}

private extension PieceKind {
    /// A stable small index for folding a promotion choice into the signature.
    var rawValueForSignature: Int {
        switch self {
        case .pawn: return 1
        case .knight: return 2
        case .bishop: return 3
        case .rook: return 4
        case .queen: return 5
        case .king: return 6
        }
    }
}

extension Duration {
    /// Whole-plus-fractional seconds as a `Double`.
    var seconds: Double {
        let (secs, atto) = components
        return Double(secs) + Double(atto) / 1e18
    }
}
