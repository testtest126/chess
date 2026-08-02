import ChessKit
import Foundation

/// Loads opening positions from an EPD file — the format used by
/// [testtest126/books](https://github.com/testtest126/books)' opening suites
/// (e.g. `2moves_v1.epd`, `noob_3moves.epd`), so a much larger and more varied
/// set than the built-in ``Openings/standard`` can be wired in when a run
/// warrants it (see the README for how to point the harness at one).
///
/// An EPD line is a FEN's first four fields (placement, side, castling,
/// en passant) optionally followed by halfmove/fullmove counters and/or EPD
/// operations (`bm e4; id "pos1";`); this repo's own books fork happens to
/// store full 6-field FEN per line with no operations, so both shapes are
/// accepted: missing counters default to `0 1`, and anything from a 7th token
/// on is ignored.
public enum EPD {
    /// Parses every line into an ``Opening``, skipping blank lines and any
    /// line that doesn't produce a legal board (this is external data, not a
    /// hardcoded suite, so malformed rows are skipped rather than trapped).
    /// Openings are named `"<basename>#<line number>"`.
    public static func loadOpenings(from path: String) -> [Opening] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let baseName = (path as NSString).lastPathComponent
        var openings: [Opening] = []
        for (index, rawLine) in contents.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let fen = normalizedFEN(line), Board(fen: fen) != nil else { continue }
            openings.append(Opening(name: "\(baseName)#\(index + 1)", fen: fen))
        }
        return openings
    }

    /// Pads a 4-field EPD position to a full 6-field FEN (default halfmove 0,
    /// fullmove 1) and drops any EPD operations beyond the 6th field. Returns
    /// `nil` if there are fewer than 4 fields.
    static func normalizedFEN(_ line: String) -> String? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 4 else { return nil }
        var six = Array(fields.prefix(6))
        if six.count < 5 { six.append("0") }
        if six.count < 6 { six.append("1") }
        return six.joined(separator: " ")
    }

    /// Deterministically samples `count` openings (without replacement) from
    /// `openings` using a seeded shuffle — the same `openings`/`count`/`seed`
    /// always picks the same subset in the same order, so a run against a
    /// large external suite still reproduces exactly.
    public static func sample(_ openings: [Opening], count: Int, seed: UInt64) -> [Opening] {
        guard count < openings.count else { return openings }
        guard count > 0 else { return [] }

        var pool = openings
        var rng = SplitMix64(seed: seed)
        // Partial Fisher–Yates: only shuffle as many slots as needed.
        for i in 0..<count {
            let j = i + Int(rng.next() % UInt64(pool.count - i))
            pool.swapAt(i, j)
        }
        return Array(pool.prefix(count))
    }
}

/// Minimal splitmix64 PRNG, used only for deterministic opening sampling —
/// mirrors the same well-known algorithm this repo already uses elsewhere for
/// seeded, reproducible selection.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
