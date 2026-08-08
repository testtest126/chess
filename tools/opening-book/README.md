# Opening book generation

`OpeningBook.large` (`ChessKit/Sources/ChessProtocol/OpeningBook.swift`) is
built from `ChessKit/Sources/ChessProtocol/Resources/opening_book_large.txt`,
a compact, frequency-weighted table generated offline by
`generate_opening_book.py` in this directory. `generate_opening_book.py
--source` supports three ways to build that table; see below.

## Current book: Lichess monthly dump (`lichess-dump`)

The bundled `opening_book_large.txt` was built by streaming a Lichess
standard-rated monthly database dump (`database.lichess.org`) through
`zstdcat` straight into the generator — the multi-GB `.pgn.zst` is never
downloaded to disk, and the stream is cut off well before the file ends:

```
pip install python-chess
curl -sL --max-time 1700 --retry 3 --retry-delay 5 \
  https://database.lichess.org/standard/lichess_db_standard_rated_2026-07.pgn.zst \
  | zstdcat \
  | python3 generate_opening_book.py --source lichess-dump \
      --min-elo 1800 --max-plies 14 --min-games 4 --max-rows 50000 \
      --max-games 3000000 --max-seconds 1500 \
      --output ../../ChessKit/Sources/ChessProtocol/Resources/opening_book_large.txt
```

(Find the latest dump filename at
`https://database.lichess.org/standard/list.txt`.)

Only games where **both** players are rated `--min-elo` (default 1800) or
higher count, so the book reflects strong-player theory rather than the
average Lichess game. For each qualifying game, the first `--max-plies`
half-moves (14 by default — 7 full moves) are walked and each `(prefix,
next move)` pair's weight accumulates a **result-aware score for the side
that played it**: 3 points if that side went on to win the game, 2 for a
draw, 1 for a loss (never 0, so a move that only ever lost still keeps a
sliver of weight, but a mostly-winning move clearly outweighs an
equally-frequent mostly-losing one). Pairs seen in fewer than `--min-games`
games are dropped as noise, and the table is capped at `--max-rows`,
highest-scoring first.

Bounded by construction so it always terminates: `--max-games` caps how
many games are *scanned* (not just accepted, since most of the dump is
below the Elo floor), `--max-seconds` is a wall-clock budget checked
periodically, and `curl --max-time` is a hard stop even if the network
stalls completely between checks (a fully-stalled read would otherwise
block the periodic check itself). Malformed PGN, ambiguous SAN, and stream
errors are skipped/logged rather than aborting the run — real external data
isn't hand-reviewed line by line.

The current bundled book: **50,000 rows, 14 plies deep**, built from
3,000,000 scanned games (1,000,785 passing the >= 1800 Elo filter) out of
the July 2026 standard-rated dump, ~2.1 MB.

## Superseded: local PGN file (`file`, the default `--source`)

The original generator mode, kept for backward compatibility and still the
default when `--source` is omitted. Walks a local PGN file's games and
counts raw `(prefix, next move)` frequency (no result weighting, no Elo
filter) — this is how the very first `opening_book_large.txt` (4,000 rows,
10 plies, ~155 KB) was built from
[testtest126/books](https://github.com/testtest126/books)'
`bjbraams_chessdb_198350_lines.pgn`, a 198,350-game real chess database
export. (That repo turned out to otherwise be engine-testing opening
suites — EPD/PGN files with no real move-frequency signal — this was the
one file in it that carried genuine played-game data.)

```
python3 generate_opening_book.py bjbraams_chessdb_198350_lines.pgn \
  ../../ChessKit/Sources/ChessProtocol/Resources/opening_book_large.txt
```

## Not yet used: live Lichess Opening Explorer (`lichess-explorer`)

`explorer.lichess.ovh`'s query endpoints (`/masters`, `/lichess`) now
require an Authorization header — a token-free request gets `401
Authorization Required`. `--source lichess-explorer` is wired up for the
day a token becomes available, but is **not part of the current
regeneration flow** and hasn't been run.

```
export LICHESS_TOKEN=...
python3 generate_opening_book.py --source lichess-explorer \
  --db masters,lichess --min-rating 2000 --max-plies 12 --max-nodes 20000 \
  --output ../../ChessKit/Sources/ChessProtocol/Resources/opening_book_large.txt
```

It breadth-first expands the opening tree directly from the API instead of
counting local game data: starting at the initial position, it queries the
selected DBs (`masters`, FIDE-rated OTB games; `lichess`, filtered to
`--min-rating` and above via the API's rating buckets), keeps moves seen in
at least `--min-move-games` games and at least `--min-freq` share of that
position's total games, and recurses into each kept move up to
`--max-plies` deep or `--max-nodes` visited positions, whichever comes
first — so it always terminates. Weighting is the same win/draw/loss score
as `lichess-dump`, computed directly from the API's per-move result counts.
Responses are cached to disk (`--cache-dir`) so a re-run doesn't re-fetch
positions it already has, requests are spaced `--rate-limit-delay` seconds
apart, and transient errors (429, 5xx) retry with exponential backoff up to
`--max-retries` times — polite by construction, not just by accident.

## Output format

One row per line, in every mode:

```
<space-separated UCI prefix>|<UCI move>|<weight>
```

`prefix` is empty for a move played from the initial position. `OpeningBook`
replays each row's own prefix through `ChessKit`'s `Game` to find the
position (reusing the exact same legality checks and `repetitionKey` hashing
`OpeningBook.standard` already relies on), so a malformed or illegal row is
just skipped rather than corrupting the book.
