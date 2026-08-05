import ChessKit
import ChessProtocol

/// Configuration for one A/B run: a fixed `baseline` config held constant
/// (the "neutral opponent" — typically ``DefaultEvaluator`` at some search
/// limit) played against a `candidate` config that differs only in what a
/// harness caller wants to measure — usually just its ``PositionEvaluator``,
/// though nothing stops comparing search limits or books too. Every opening in
/// `openings` is played twice with colors swapped, exactly like
/// ``SelfPlay/playMatch(a:b:openings:maxPlies:)``, so color bias cancels.
public struct ABTestConfig: Sendable {
    public let baseline: EngineConfig
    public let candidate: EngineConfig
    public let openings: [Opening]
    public let maxPlies: Int
    public let sprt: SPRT.Parameters
    /// Hard cap on games played even if SPRT never resolves. `nil` plays the
    /// whole `openings` schedule (`2 × openings.count` games).
    public let maxGames: Int?

    public init(
        baseline: EngineConfig,
        candidate: EngineConfig,
        openings: [Opening] = Openings.standard,
        maxPlies: Int = SelfPlay.defaultMaxPlies,
        sprt: SPRT.Parameters,
        maxGames: Int? = nil
    ) {
        self.baseline = baseline
        self.candidate = candidate
        self.openings = openings
        self.maxPlies = maxPlies
        self.sprt = sprt
        self.maxGames = maxGames
    }
}

/// One played game, kept for transparency and for the harness's own
/// determinism tests (a full replay should reproduce every record exactly).
public struct ABTestGameRecord: Sendable, Equatable {
    public let openingName: String
    public let candidateIsWhite: Bool
    public let result: GameResult
    public let reason: GameEndReason
    public let plies: Int
}

/// Result of an A/B run, from the candidate's perspective (mirrors
/// ``MatchResult``, with the addition of the SPRT verdict and per-game log).
public struct ABTestResult: Sendable {
    public let candidateLabel: String
    public let baselineLabel: String
    public let wins: Int
    public let draws: Int
    public let losses: Int
    public let games: [ABTestGameRecord]
    public let sprt: SPRT.Result
    /// The 1-indexed game count at which SPRT first left `.continueTesting`,
    /// or `nil` if the whole schedule ran out without a decision.
    public let sprtDecidedAtGame: Int?

    public var gamesPlayed: Int { wins + draws + losses }

    /// Candidate's score fraction: (wins + ½·draws) / games.
    public var scoreCandidate: Double {
        guard gamesPlayed > 0 else { return 0 }
        return (Double(wins) + 0.5 * Double(draws)) / Double(gamesPlayed)
    }

    /// Elo of candidate relative to baseline (positive ⇒ candidate is stronger).
    public var eloDelta: Double { Elo.difference(forScore: scoreCandidate) }
    /// 95% confidence half-width around `eloDelta`.
    public var eloMargin: Double { Elo.errorMargin95(wins: wins, draws: draws, losses: losses) }
}

/// The A/B measurement harness: candidate vs. a fixed baseline, many games
/// from varied openings, both colors, with an SPRT check after every game so
/// a confident result can stop well short of the full schedule. Fully
/// deterministic — no clocks, no unseeded randomness — so a run reproduces
/// exactly given the same `ABTestConfig` (assuming neither `EngineConfig`
/// carries a book, same caveat as ``SelfPlay``).
public enum ABTest {
    private struct ScheduledGame {
        let opening: Opening
        let candidateIsWhite: Bool
    }

    public static func run(_ config: ABTestConfig) -> ABTestResult {
        var schedule: [ScheduledGame] = []
        for opening in config.openings {
            schedule.append(ScheduledGame(opening: opening, candidateIsWhite: true))
            schedule.append(ScheduledGame(opening: opening, candidateIsWhite: false))
        }
        if let maxGames = config.maxGames, maxGames < schedule.count {
            schedule = Array(schedule.prefix(maxGames))
        }

        var wins = 0
        var draws = 0
        var losses = 0
        var records: [ABTestGameRecord] = []
        records.reserveCapacity(schedule.count)
        var sprtResult = SPRT.evaluate(wins: 0, draws: 0, losses: 0, parameters: config.sprt)
        var decidedAtGame: Int?

        for scheduled in schedule {
            let start = parseFEN(scheduled.opening.fen)
            let white = scheduled.candidateIsWhite ? config.candidate : config.baseline
            let black = scheduled.candidateIsWhite ? config.baseline : config.candidate
            let outcome = SelfPlay.playGame(white: white, black: black, from: start, maxPlies: config.maxPlies)

            switch outcome.result {
            case .draw:
                draws += 1
            case .whiteWin:
                if scheduled.candidateIsWhite { wins += 1 } else { losses += 1 }
            case .blackWin:
                if scheduled.candidateIsWhite { losses += 1 } else { wins += 1 }
            }
            records.append(ABTestGameRecord(
                openingName: scheduled.opening.name,
                candidateIsWhite: scheduled.candidateIsWhite,
                result: outcome.result, reason: outcome.reason, plies: outcome.plies
            ))

            sprtResult = SPRT.evaluate(wins: wins, draws: draws, losses: losses, parameters: config.sprt)
            if sprtResult.decision != .continueTesting {
                decidedAtGame = records.count
                break
            }
        }

        return ABTestResult(
            candidateLabel: config.candidate.label,
            baselineLabel: config.baseline.label,
            wins: wins, draws: draws, losses: losses,
            games: records,
            sprt: sprtResult,
            sprtDecidedAtGame: decidedAtGame
        )
    }
}
