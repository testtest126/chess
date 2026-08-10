# mate-uci — UCI executable

Speaks the [UCI protocol](https://en.wikipedia.org/wiki/Universal_Chess_Interface)
over stdin/stdout, so any UCI-speaking GUI or bridge (a desktop chess GUI,
`cutechess-cli`, or the [`lichess-bot`](https://github.com/lichess-bot-devs/lichess-bot)
bridge for Lichess's Bot API) can drive `ChessKit-Negamax`.

All protocol logic lives in `ChessProtocol.UCIEngine` (unit-tested by
`ChessProtocolTests/UCITests.swift`); this target is a thin shim that wires it
to a `PersistentNegamaxEngine` — chosen over the plain value-type
`NegamaxEngine` because its transposition table survives across the searches
within one game, matching how a real UCI GUI/bridge drives an engine — plus
the `.large` opening book.

## Build

```
swift build -c release --product mate-uci
```

Use `-c release`: same as `engine-lab`, a debug build is tens of times
slower.

## Run

```
swift run -c release mate-uci
```

or point a GUI/bridge at the built binary directly:
`.build/release/mate-uci`.

## Supported commands

| Command | Notes |
|---|---|
| `uci` | replies `id name`, `id author`, `uciok` |
| `isready` | replies `readyok` |
| `ucinewgame` | resets to the starting position |
| `position startpos [moves ...]` | |
| `position fen <FEN> [moves ...]` | |
| `go depth <n>` | fixed-depth search |
| `go nodes <n>` | fixed node budget |
| `go movetime <ms>` | fixed per-move time budget |
| `go wtime <ms> btime <ms> [winc <ms>] [binc <ms>]` | clock-derived time budget for the side to move (see below) |
| `quit` | exits the read loop |

`go` with no limit at all falls back to a fixed low depth — mainly useful
for manual testing; a real GUI/bridge always sends one of the above.

### Clock management

When `wtime`/`btime` are sent, `mate-uci` budgets roughly 1/20th of the
remaining time plus 80% of the incoming increment for the side to move,
capped at half the remaining clock, with a safety margin held back so an
in-progress search iteration finishing slightly late doesn't flag the clock.
See `UCIEngine.clockBudget` in `ChessProtocol/UCI.swift` for the exact
formula and `UCITests` for its test coverage.

## Example session

```
$ swift run -c release mate-uci
uci
id name MateMate
id author testtest126/chess
uciok
isready
readyok
ucinewgame
position startpos
go movetime 1000
info depth 8 score cp 25 nodes 184213
bestmove e2e4
position startpos moves e2e4 e7e5
go wtime 60000 btime 60000 winc 1000 binc 1000
info depth 10 score cp 32 nodes 512044
bestmove g1f3
quit
```

## Wiring to Lichess (deployment — not part of this repo's scope)

This target only speaks UCI locally; it has no knowledge of Lichess or
network I/O. To actually play on Lichess:

1. Build `mate-uci` (above).
2. Run the maintained
   [`lichess-bot`](https://github.com/lichess-bot-devs/lichess-bot) bridge,
   pointed at the `mate-uci` binary as its engine executable. `lichess-bot`
   speaks the Bot API on one side and UCI on the other — no bot-specific code
   is needed in this repo.
3. `lichess-bot` needs a Lichess bot account and a `bot:play`-scoped OAuth
   token, supplied via an env var at deploy time — same pattern as
   `$LICHESS_TOKEN` used by `tools/opening-book/`. The account and token are
   created and held outside of any agent session.
4. `lichess-bot` + `mate-uci` need to run continuously (an always-on host) to
   keep the bot account available for challenges.

See issue #216 for the full plan and #214 for why the bot's live rating
matters (external strength benchmark).
