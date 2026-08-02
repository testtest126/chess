# EngineLab — engine measurement harness

Tooling to measure strength and speed changes in `ChessKit-Negamax`
(`ChessProtocol/NegamaxEngine.swift`). It is the prerequisite for any engine
tuning: without it, an "improvement" can't be told from a regression.

EngineLab is an **internal, non-shipping** package target — it is not exported
as a library product, so it is never linked into the iOS app. It only *calls*
the engine's `search`, so the engine's determinism guarantee is untouched.

## Tools

Everything runs through the `engine-lab` executable (all logic lives in the
`EngineLab` target and is unit-tested; the executable is a one-line shim):

```
swift run -c release engine-lab bench   [--nodes N | --depth D]
swift run -c release engine-lab match   [--depth-a D] [--depth-b D]
                                        [--nodes-a N] [--nodes-b N]
                                        [--games G] [--max-plies P]
swift run -c release engine-lab abtest  [--depth D] [--baseline-depth D] [--candidate-depth D]
                                        [--elo0 E0] [--elo1 E1] [--alpha A] [--beta B]
                                        [--draw-prob P] [--games G] [--max-plies P]
                                        [--epd PATH [--sample N [--seed S]]]
```

Use `-c release` — the search is only a few hundred thousand nodes/sec, so a
debug build is ~40× slower.

### `bench`

Searches a fixed 20-position suite (openings, tactical middlegames, endgames)
under one reproducible limit and prints total nodes, nodes/sec (a speed proxy),
and a **signature** — a checksum over every position's best move, score, depth,
and node count.

```
$ swift run -c release engine-lab bench --nodes 2000
ChessKit-Negamax bench
limit: nodes<=2000 (depth ceiling 64)

  startpos           depth   4  score       +0  nodes       2000  b1c3
  ...
positions: 20   total nodes: 42798   time: 0.33s   speed: 0.13 Mnps
signature: 0xcd7fa918c21eafc2
```

The signature is a **determinism regression guard**: it is byte-identical on
every machine and every run (engine evaluation is pure integer), and moves only
when search behavior changes. It is pinned in `EngineLabTests`; a behavior
change trips CI, and the fix is to update the pinned value in the same PR — that
diff is the review signal. With a fixed `--depth`, the *total node count* is
itself the fingerprint.

### `match`

Plays an engine-vs-engine self-play match: every opening in a small balanced set
is played twice, colors swapped, so color bias cancels. Reports W/D/L, score %,
and Elo(A − B) with a 95% error margin.

```
$ swift run -c release engine-lab match --depth-a 3 --depth-b 1
Self-play match
A: depth-3    B: depth-1
games: 24  (12 openings × 2 colors)
A results: +15 =9 -0   score: 81.2%
Elo(A - B): +255 ± 120  (95%)
```

Limits are fixed **nodes or depth** — never wall-clock — so a match is fully
reproducible. Two configs that differ only in depth (or node budget) measure how
much that extra search is worth in Elo. To compare two *versions* of the engine,
build the tool on each commit and run the same match; the fixed limits make the
numbers comparable.

Leave books off (the default) to keep games deterministic — a book's random move
choice would make runs non-reproducible.

### `abtest`

The trustworthy way to measure a candidate evaluation function, replacing an
earlier throwaway harness that flipped a `nonisolated(unsafe) static var` on
`Eval` mid-game — clever for a quick check, useless as anything permanent:
shared mutable state that only one config could see at a time, no seam a
harness could plug a real candidate into, and no way to run two configurations
concurrently. That's gone. In its place:

- **A clean seam, not a switch.** `NegamaxEngine`/`PersistentNegamaxEngine` now
  take an `evaluator: any PositionEvaluator` (`ChessProtocol/PositionEvaluator.swift`)
  — the *only* place static evaluation happens in the search (the quiescence
  stand-pat). It defaults to `DefaultEvaluator` (the shipping evaluation,
  unchanged for every existing caller), so two engine instances built with
  different evaluators are fully independent — no shared state, safe to run
  interleaved or concurrently. `EngineConfig.evaluator` is how a harness picks
  one; `MaterialOnlyEvaluator` (material count, no piece-square tables) ships
  here as a concrete example — both to prove the seam actually changes search
  behavior (see `PositionEvaluatorTests`) and to give `abtest` something real
  and fast to compare by default, without depending on a not-yet-merged
  candidate evaluator.
- **A fixed baseline, not head-to-head self-play.** `candidate` plays against
  `baseline` — a config held constant across the whole run (by default,
  `DefaultEvaluator`, i.e. today's shipping evaluation) — across every opening,
  both colors, exactly like `match`.
- **An SPRT, so a confident run can stop early.** After every game, an SPRT
  (`SPRT.swift`) checks whether the evidence already supports "candidate is no
  better than `--elo0`" (H0) or "candidate is at least `--elo1` Elo stronger"
  (H1); the run stops the moment either bound is crossed instead of always
  playing every game. See "The SPRT model" below for the (explicitly stated)
  simplifying assumption it makes.
- **Real Elo + a 95% margin**, via the same `Elo` module `match` uses.
- **Varied openings** via the built-in `Openings.standard` set (12 openings ×
  2 colors), or `--epd PATH` to point at a larger suite instead — including
  [testtest126/books](https://github.com/testtest126/books)' EPD files (e.g.
  `2moves_v1.epd`, `noob_3moves.epd`) — with `--sample N --seed S` to
  deterministically draw N positions from it (the same N positions, same
  order, every time, for the same seed).
- **Fully deterministic** — no clocks, no unseeded randomness anywhere in the
  pipeline (search limits, evaluators, and opening sampling are all either
  fixed or explicitly seeded) — so a run reproduces exactly, down to every
  individual game's result and length.

```
$ swift run -c release engine-lab abtest --depth 3 --elo0 -30 --elo1 30
A/B eval measurement
candidate: candidate (MaterialOnlyEvaluator)    baseline: baseline (DefaultEvaluator)
games: 11 — SPRT decided here
candidate results: +0 =2 -9   score: 9.1%
Elo(candidate - baseline): -400 ± 542  (95%)
SPRT: llr -3.13 (bounds -2.94 .. 2.94) -> H0 accepted — candidate is not an improvement
```

This run correctly and quickly rejects "no piece-square tables" as an
improvement: SPRT stopped after 11 of the 24 scheduled games, well short of
the full schedule, once the losses piled up enough to cross the lower bound.
`--elo0`/`--elo1` set how coarse or fine the test is — a **wide** gap (like
the `-30`/`+30` above) is a fast, coarse screening pass that resolves in few
games when the true effect is large; a **narrow** gap (the CLI's default,
`0`/`+10`, standard for a fine-grained "is this really an improvement, however
small" test) needs far more games to resolve at all, and won't reach a verdict
within the built-in 24-game schedule for anything but a large effect — that's
expected SPRT behavior, not a bug. Point `--games` at a larger cap, or `--epd`
at a bigger suite, for a narrow-gap test to have a chance of resolving.

#### The SPRT model

Chess-engine SPRT (fishtest, cutechess-cli `--sprt`) is normally run over the
full pentanomial/paired-openings distribution of results, which lets the draw
rate itself carry information. This implementation makes a simpler, explicitly
stated assumption instead: a single assumed draw probability
(`--draw-prob`, default `0.5`) is held **fixed and shared** between both
hypotheses, so **draws contribute nothing to the log-likelihood ratio** — only
decisive games move it. This needs no extra parameter estimation and is exact
for the two-hypothesis test as long as that constant-draw-rate assumption
roughly holds; it is *not* a bit-exact port of fishtest's statistic. See the
doc comment on `SPRT.Parameters` for the derivation, and `SPRTTests` for the
boundary-crossing and "draws don't move the LLR" properties pinned as tests.

## What CI guards

`swift test` (the `ChessKit tests` lane) runs `EngineLabTests`:

- the bench signature is stable across two runs and matches its pinned snapshot;
- Elo conversion and error-margin math;
- self-play mechanics: identical engines net exactly even (color-swap fairness),
  a deeper config outscores a shallower one (the Elo pipeline points the right
  way), games are reproducible, and every game terminates;
- the `PositionEvaluator` seam is actually consulted by both engine types, not
  silently bypassed (`ChessProtocolTests.PositionEvaluatorTests`);
- SPRT math: bounds widen with tighter error rates, a long run of wins/losses
  eventually crosses the corresponding bound, draws never move the LLR, and
  the verdict is a pure function of the W/D/L totals (`SPRTTests`);
- EPD parsing (field padding, opcode stripping, malformed-line skipping) and
  seeded sampling — same seed ⇒ same subset/order, different seed ⇒ (almost
  certainly) different (`EPDTests`);
- the `abtest` harness end to end: identical evaluators net even, a materially
  worse candidate scores and Elos below the baseline, SPRT actually stops a
  run before the full schedule when the evidence is one-sided, `--games` caps
  the schedule when SPRT never resolves, and a full run — every game's result,
  not just the aggregate — reproduces exactly (`ABTestTests`).
