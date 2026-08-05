#!/usr/bin/env python3
"""Build a compact, frequency-weighted opening book from real game data.

Source: testtest126/books' bjbraams_chessdb_198350_lines.pgn (a real chess
database export, 198,350 lines up to 16 plies deep) -- chosen over the
repo's other PGN/EPD files because it's actual played-game continuations,
not randomly-generated or eval-balanced test positions, so move frequency
at a given position is a genuine popularity signal.

For every game, walks the first MAX_PLIES plies and, at each ply, records
(prefix, next move) -> count, where prefix is the space-separated UCI move
sequence from the start position. Prefixes are then filtered to only keep
(prefix, move) pairs seen at least MIN_WEIGHT times, and the whole table is
capped at MAX_ROWS rows (highest weight first) to keep the generated book
small. Output format, one row per line: "<prefix>|<uci move>|<weight>"
(prefix is empty for the very first move).

Usage: python3 generate_opening_book.py <input.pgn> <output.txt>
"""
import sys
from collections import Counter

import chess.pgn

MAX_PLIES = 10  # 5 full moves -- matches the hand-authored book's own scope
MIN_WEIGHT = 5  # drop pairs seen in fewer than this many games (cuts noise)
MAX_ROWS = 4000  # hard cap so the generated book stays compact


def main():
    in_path, out_path = sys.argv[1], sys.argv[2]
    counts = Counter()  # (prefix_str, move_uci) -> count
    games = 0

    with open(in_path, encoding="utf-8", errors="replace") as f:
        while True:
            game = chess.pgn.read_game(f)
            if game is None:
                break
            games += 1
            board = game.board()
            prefix = []
            for i, move in enumerate(game.mainline_moves()):
                if i >= MAX_PLIES:
                    break
                key = (" ".join(prefix), move.uci())
                counts[key] += 1
                prefix.append(move.uci())
                board.push(move)

    print(f"parsed {games} games, {len(counts)} distinct (prefix, move) pairs", file=sys.stderr)

    filtered = [(k, w) for k, w in counts.items() if w >= MIN_WEIGHT]
    filtered.sort(key=lambda kw: -kw[1])
    filtered = filtered[:MAX_ROWS]
    print(f"kept {len(filtered)} rows after weight>={MIN_WEIGHT} filter and top-{MAX_ROWS} cap", file=sys.stderr)

    with open(out_path, "w", encoding="utf-8") as out:
        for (prefix, move), weight in filtered:
            out.write(f"{prefix}|{move}|{weight}\n")


if __name__ == "__main__":
    main()
