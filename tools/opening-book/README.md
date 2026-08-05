# Opening book generation

`OpeningBook.large` (`ChessKit/Sources/ChessProtocol/OpeningBook.swift`) is
built from `ChessKit/Sources/ChessProtocol/Resources/opening_book_large.txt`,
a compact, frequency-weighted table generated offline by
`generate_opening_book.py` in this directory.

## Source data

[testtest126/books](https://github.com/testtest126/books) turns out to be a
collection of *engine-testing opening suites* (EPD/PGN files used to vary
start positions across engine-vs-engine matches), not a curated, weighted
move-selection book — there's no Polyglot `.bin` anywhere in it. Its EPD
files are one bare FEN per line with no move or frequency data, and its PGN
files are mostly single, computer-generated move sequences (one balanced or
eval-filtered line per "game"), so they don't carry a real popularity signal
either.

The one file in that repo that does carry a genuine signal is
`bjbraams_chessdb_198350_lines.pgn` — 198,350 lines pulled from a real chess
database, i.e. actual played-game continuations. Because real games converge
onto the same well-known lines early on, counting how often each move follows
a given position across all 198,350 games gives real move-popularity weights,
the same idea a Polyglot book's weights encode, just computed here instead of
read from a `.bin`.

## Regenerating

```
pip install python-chess
curl -LO https://github.com/testtest126/books/raw/main/bjbraams_chessdb_198350_lines.pgn.zip
unzip bjbraams_chessdb_198350_lines.pgn.zip
python3 generate_opening_book.py bjbraams_chessdb_198350_lines.pgn \
  ../../ChessKit/Sources/ChessProtocol/Resources/opening_book_large.txt
```

The script walks each game's first `MAX_PLIES` plies (10, i.e. 5 full moves —
matches the hand-authored `OpeningBook.standard`'s own stated scope), counts
`(prefix, next move)` occurrences, keeps pairs seen at least `MIN_WEIGHT`
times (5, to drop one-off noise and transcription errors) and caps the result
at `MAX_ROWS` rows (4000, highest weight first) so the generated book stays
small — the current output is ~155 KB for 4000 rows spanning the initial
position through 5 full moves deep.

Output format, one row per line:

```
<space-separated UCI prefix>|<UCI move>|<weight>
```

`prefix` is empty for a move played from the initial position. `OpeningBook`
replays each row's own prefix through `ChessKit`'s `Game` to find the
position (reusing the exact same legality checks and `repetitionKey` hashing
`OpeningBook.standard` already relies on), so a malformed or illegal row is
just skipped rather than corrupting the book.
