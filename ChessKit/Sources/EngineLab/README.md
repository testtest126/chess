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
swift run -c release engine-lab bench  [--nodes N | --depth D]
swift run -c release engine-lab match  [--depth-a D] [--depth-b D]
                                       [--nodes-a N] [--nodes-b N]
                                       [--games G] [--max-plies P]
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

## What CI guards

`swift test` (the `ChessKit tests` lane) runs `EngineLabTests`:

- the bench signature is stable across two runs and matches its pinned snapshot;
- Elo conversion and error-margin math;
- self-play mechanics: identical engines net exactly even (color-swap fairness),
  a deeper config outscores a shallower one (the Elo pipeline points the right
  way), games are reproducible, and every game terminates.
