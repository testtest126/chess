#!/usr/bin/env python3
"""Build a compact, frequency-weighted opening book from real game data.

Three sources, selected with --source:

  file (default, unchanged from the original tool)
      Walks a local PGN file's games, matching the exact behavior that built
      the currently-bundled `opening_book_large.txt` from
      bjbraams_chessdb_198350_lines.pgn. See tools/opening-book/README.md.

  lichess-dump
      Streams PGN text on stdin -- pipe a Lichess monthly database dump
      through `zstdcat` without ever storing the multi-GB file:

        curl -sL https://database.lichess.org/standard/lichess_db_standard_rated_2026-07.pgn.zst \\
          | zstdcat \\
          | python3 generate_opening_book.py --source lichess-dump \\
              --min-elo 1800 --max-games 3000000 --max-seconds 1500 \\
              --output opening_book_large.txt

      Filters to games where both players are rated >= --min-elo, walks each
      qualifying game's first --max-plies plies, and weights each
      (prefix, move) pair by a result-aware score (see WHITE_SCORE below) --
      not just raw frequency -- so a move that tends to win outweighs one
      played equally often but losing. Bounded by --max-games (games
      scanned, not just accepted) and --max-seconds wall clock, whichever
      comes first, so it always terminates even on a stalled or huge stream.

  lichess-explorer
      Breadth-first expands the opening tree by querying the live Lichess
      Opening Explorer API (masters and/or lichess DB) instead of parsing
      game data locally. Needs a Lichess API token in the environment
      variable named by --token-env (default LICHESS_TOKEN) -- the explorer
      endpoints started requiring auth for programmatic use. Not invoked as
      part of the normal regeneration flow; wired up so that supplying a
      token later is a one-command regenerate. Polite by default: disk
      caching (--cache-dir), a delay between requests (--rate-limit-delay),
      and retry-with-backoff on transient errors.

Output format is the same in every mode, one row per line:

  <space-separated UCI prefix>|<UCI move>|<weight>

`prefix` is empty for a move played from the initial position. `OpeningBook`
replays each row's own prefix to find the position, so a malformed or
illegal row is just skipped rather than corrupting the book.
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter

import chess
import chess.pgn

# --- file mode (original behavior, unchanged) -------------------------------

MAX_PLIES = 10  # 5 full moves -- matches the hand-authored book's own scope
MIN_WEIGHT = 5  # drop pairs seen in fewer than this many games (cuts noise)
MAX_ROWS = 4000  # hard cap so the generated book stays compact


def run_file_mode(in_path, out_path):
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

    write_rows(out_path, filtered)


# --- lichess-dump mode --------------------------------------------------------

_COMMENT_RE = re.compile(r"\{[^}]*\}")
_NAG_RE = re.compile(r"\$\d+")
_MOVE_NUMBER_RE = re.compile(r"^\d+\.+$")
_RESULT_TOKENS = {"1-0", "0-1", "1/2-1/2", "*"}
_HEADER_RE = re.compile(r'^\[(\w+)\s+"(.*)"\]\s*$')

# Per-game contribution to a (prefix, move) pair's weight, keyed by how the
# game ended for the side that played that move -- never zero, so a move
# that only ever lost still keeps some weight, but a mostly-winning move
# outweighs an equally-frequent mostly-losing one.
WIN_SCORE, DRAW_SCORE, LOSS_SCORE = 3, 2, 1


def _iter_dump_games(stream):
    """Yields (headers: dict, movetext: str) for each game in a PGN stream."""
    headers = {}
    movetext_lines = []
    mode = "header"
    for raw_line in stream:
        line = raw_line.rstrip("\n")
        if mode == "header":
            m = _HEADER_RE.match(line)
            if m:
                headers[m.group(1)] = m.group(2)
            elif line == "":
                mode = "movetext"
            # else: stray line before headers resume -- ignore
        else:
            if line == "":
                yield headers, " ".join(movetext_lines)
                headers = {}
                movetext_lines = []
                mode = "header"
            else:
                movetext_lines.append(line)
    if headers or movetext_lines:
        yield headers, " ".join(movetext_lines)


def _tokenize_movetext(movetext):
    text = _COMMENT_RE.sub(" ", movetext)
    text = _NAG_RE.sub(" ", text)
    tokens = []
    for tok in text.split():
        if _MOVE_NUMBER_RE.match(tok) or tok in _RESULT_TOKENS:
            continue
        tokens.append(tok.rstrip("!?"))
    return tokens


def run_lichess_dump_mode(out_path, min_elo, max_plies, min_games, max_rows, max_games, max_seconds):
    # (prefix, move) -> [games_count, weighted_score]
    stats = {}
    games_scanned = 0
    games_accepted = 0
    started = time.monotonic()
    stop_reason = "stdin exhausted"

    try:
        sys.stdin.reconfigure(errors="replace")
    except AttributeError:
        pass

    try:
        for headers, movetext in _iter_dump_games(sys.stdin):
            games_scanned += 1

            if games_scanned % 5000 == 0:
                elapsed = time.monotonic() - started
                print(
                    f"...scanned {games_scanned} games ({games_accepted} accepted, "
                    f"{len(stats)} pairs, {elapsed:.0f}s elapsed)",
                    file=sys.stderr,
                )
                if elapsed >= max_seconds:
                    stop_reason = f"hit --max-seconds ({max_seconds}s)"
                    break
            if games_scanned >= max_games:
                stop_reason = f"hit --max-games ({max_games})"
                break

            result = headers.get("Result")
            if result not in ("1-0", "0-1", "1/2-1/2"):
                continue
            try:
                white_elo = int(headers.get("WhiteElo", ""))
                black_elo = int(headers.get("BlackElo", ""))
            except ValueError:
                continue
            if white_elo < min_elo or black_elo < min_elo:
                continue

            tokens = _tokenize_movetext(movetext)
            if not tokens:
                continue

            board = chess.Board()
            prefix = []
            games_accepted += 1
            try:
                for i, san in enumerate(tokens):
                    if i >= max_plies:
                        break
                    move = board.parse_san(san)
                    uci = move.uci()
                    white_to_move = board.turn == chess.WHITE
                    if result == "1/2-1/2":
                        score = DRAW_SCORE
                    elif (result == "1-0") == white_to_move:
                        score = WIN_SCORE
                    else:
                        score = LOSS_SCORE

                    key = (" ".join(prefix), uci)
                    entry = stats.setdefault(key, [0, 0])
                    entry[0] += 1
                    entry[1] += score

                    board.push(move)
                    prefix.append(uci)
            except (ValueError, chess.IllegalMoveError, chess.AmbiguousMoveError):
                # Malformed/ambiguous SAN partway through -- keep whatever
                # this game already contributed and move to the next one.
                continue
    except KeyboardInterrupt:
        stop_reason = "interrupted"
    except BrokenPipeError:
        stop_reason = "upstream pipe closed"

    elapsed = time.monotonic() - started
    print(
        f"stopped: {stop_reason} -- scanned {games_scanned} games, "
        f"{games_accepted} passed the >= {min_elo} Elo filter, "
        f"{len(stats)} distinct (prefix, move) pairs, {elapsed:.0f}s elapsed",
        file=sys.stderr,
    )

    filtered = [(k, score) for k, (games, score) in stats.items() if games >= min_games]
    filtered.sort(key=lambda kw: -kw[1])
    filtered = filtered[:max_rows]
    print(
        f"kept {len(filtered)} rows after games>={min_games} filter and top-{max_rows} cap",
        file=sys.stderr,
    )

    write_rows(out_path, filtered)


# --- lichess-explorer mode ----------------------------------------------------

EXPLORER_BASE = "https://explorer.lichess.ovh"
# Lichess's own rating buckets for the /lichess db's ratings[] filter.
RATING_BUCKETS = [400, 1000, 1200, 1400, 1600, 1800, 2000, 2200, 2500]


def _explorer_request(url, token, cache_dir, rate_limit_delay, max_retries):
    cache_path = None
    if cache_dir:
        os.makedirs(cache_dir, exist_ok=True)
        digest = str(abs(hash(url)))
        cache_path = os.path.join(cache_dir, f"{digest}.json")
        if os.path.exists(cache_path):
            with open(cache_path, encoding="utf-8") as f:
                return json.load(f)

    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    backoff = 1.0
    for attempt in range(max_retries + 1):
        try:
            time.sleep(rate_limit_delay)
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            if cache_path:
                with open(cache_path, "w", encoding="utf-8") as f:
                    json.dump(data, f)
            return data
        except urllib.error.HTTPError as e:
            if e.code == 429 or e.code >= 500:
                print(f"  retry {attempt + 1}/{max_retries} after HTTP {e.code}: {url}", file=sys.stderr)
                time.sleep(backoff)
                backoff *= 2
                continue
            raise
        except urllib.error.URLError as e:
            print(f"  retry {attempt + 1}/{max_retries} after {e}: {url}", file=sys.stderr)
            time.sleep(backoff)
            backoff *= 2
            continue
    raise RuntimeError(f"exhausted retries fetching {url}")


def _explorer_url(db, fen, min_rating):
    params = {"fen": fen, "topGames": "0", "recentGames": "0"}
    if db == "lichess":
        params["variant"] = "standard"
        params["speeds[]"] = ["blitz", "rapid", "classical"]
        buckets = [b for b in RATING_BUCKETS if b >= min_rating]
        query = urllib.parse.urlencode(params, doseq=True)
        query += "&" + "&".join(f"ratings[]={b}" for b in buckets)
    else:
        query = urllib.parse.urlencode(params, doseq=True)
    return f"{EXPLORER_BASE}/{db}?{query}"


def run_lichess_explorer_mode(
    out_path, token_env, dbs, min_rating, max_plies, min_move_games, min_freq,
    max_nodes, max_rows, rate_limit_delay, max_retries, cache_dir,
):
    token = os.environ.get(token_env)
    if not token:
        print(
            f"error: --source lichess-explorer needs a Lichess API token in ${token_env}. "
            "Not calling the API without one -- set the env var and re-run.",
            file=sys.stderr,
        )
        sys.exit(1)

    # (prefix, move) -> weighted_score
    stats = {}
    queue = [[]]  # each item is a list of UCI moves from the start position
    nodes_visited = 0

    while queue and nodes_visited < max_nodes:
        prefix = queue.pop(0)
        nodes_visited += 1

        board = chess.Board()
        for uci in prefix:
            board.push(chess.Move.from_uci(uci))
        fen = board.fen()
        white_to_move = board.turn == chess.WHITE

        combined_moves = {}  # uci -> [white, draws, black]
        for db in dbs:
            url = _explorer_url(db, fen, min_rating)
            try:
                data = _explorer_request(url, token, cache_dir, rate_limit_delay, max_retries)
            except (urllib.error.HTTPError, RuntimeError) as e:
                print(f"  giving up on {url}: {e}", file=sys.stderr)
                continue
            for m in data.get("moves", []):
                entry = combined_moves.setdefault(m["uci"], [0, 0, 0])
                entry[0] += m.get("white", 0)
                entry[1] += m.get("draws", 0)
                entry[2] += m.get("black", 0)

        prefix_str = " ".join(prefix)
        for uci, (white, draws, black) in combined_moves.items():
            games = white + draws + black
            if games < min_move_games:
                continue
            total = sum(sum(v) for v in combined_moves.values()) or 1
            if games / total < min_freq:
                continue

            score = (
                white * WIN_SCORE + draws * DRAW_SCORE + black * LOSS_SCORE
                if white_to_move
                else black * WIN_SCORE + draws * DRAW_SCORE + white * LOSS_SCORE
            )
            key = (prefix_str, uci)
            stats[key] = stats.get(key, 0) + score

            if len(prefix) + 1 < max_plies:
                queue.append(prefix + [uci])

        if nodes_visited % 50 == 0:
            print(f"...visited {nodes_visited} positions, {len(queue)} queued, {len(stats)} pairs", file=sys.stderr)

    print(f"stopped after {nodes_visited} positions ({len(stats)} distinct (prefix, move) pairs)", file=sys.stderr)

    filtered = sorted(stats.items(), key=lambda kw: -kw[1])[:max_rows]
    print(f"kept {len(filtered)} rows after top-{max_rows} cap", file=sys.stderr)

    write_rows(out_path, filtered)


# --- shared --------------------------------------------------------------

def write_rows(out_path, rows):
    with open(out_path, "w", encoding="utf-8") as out:
        for (prefix, move), weight in rows:
            out.write(f"{prefix}|{move}|{weight}\n")


def build_arg_parser():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("input", nargs="?", help="local PGN file (--source file only)")
    p.add_argument("output", nargs="?", help="output book path (or use --output)")
    p.add_argument("-o", "--output", dest="output_flag", help="output book path")
    p.add_argument(
        "--source", choices=["file", "lichess-dump", "lichess-explorer"], default="file",
        help="where to build the book from (default: file, the original local-PGN behavior)",
    )

    # lichess-dump
    p.add_argument("--min-elo", type=int, default=1800, help="[lichess-dump] require both players >= this Elo")
    p.add_argument("--max-plies", type=int, default=14, help="[lichess-dump/explorer] depth cap, in half-moves")
    p.add_argument("--min-games", type=int, default=4, help="[lichess-dump] drop pairs seen in fewer games than this")
    p.add_argument("--max-rows", type=int, default=50000, help="[lichess-dump/explorer] cap on output rows")
    p.add_argument("--max-games", type=int, default=3_000_000, help="[lichess-dump] stop after scanning this many games")
    p.add_argument("--max-seconds", type=float, default=1500, help="[lichess-dump] wall-clock budget before stopping")

    # lichess-explorer
    p.add_argument("--token-env", default="LICHESS_TOKEN", help="[lichess-explorer] env var holding the API token")
    p.add_argument("--db", default="masters,lichess", help="[lichess-explorer] comma-separated: masters,lichess")
    p.add_argument("--min-rating", type=int, default=2000, help="[lichess-explorer] lichess db rating floor")
    p.add_argument("--min-move-games", type=int, default=10, help="[lichess-explorer] drop moves below this game count")
    p.add_argument("--min-freq", type=float, default=0.01, help="[lichess-explorer] drop moves below this share of the position's games")
    p.add_argument("--max-nodes", type=int, default=20000, help="[lichess-explorer] hard cap on BFS positions visited")
    p.add_argument("--rate-limit-delay", type=float, default=1.0, help="[lichess-explorer] seconds between requests")
    p.add_argument("--max-retries", type=int, default=5, help="[lichess-explorer] retries on 429/5xx before giving up")
    p.add_argument("--cache-dir", default=".lichess_explorer_cache", help="[lichess-explorer] disk cache for responses")

    return p


def main():
    args = build_arg_parser().parse_args()
    output = args.output_flag or args.output

    if args.source == "file":
        if not args.input or not output:
            print("error: --source file needs <input.pgn> <output.txt>", file=sys.stderr)
            sys.exit(2)
        run_file_mode(args.input, output)
    elif args.source == "lichess-dump":
        if not output:
            print("error: --source lichess-dump needs -o/--output <output.txt>", file=sys.stderr)
            sys.exit(2)
        run_lichess_dump_mode(
            output, args.min_elo, args.max_plies, args.min_games, args.max_rows,
            args.max_games, args.max_seconds,
        )
    elif args.source == "lichess-explorer":
        if not output:
            print("error: --source lichess-explorer needs -o/--output <output.txt>", file=sys.stderr)
            sys.exit(2)
        dbs = [d.strip() for d in args.db.split(",") if d.strip()]
        run_lichess_explorer_mode(
            output, args.token_env, dbs, args.min_rating, args.max_plies,
            args.min_move_games, args.min_freq, args.max_nodes, args.max_rows,
            args.rate_limit_delay, args.max_retries, args.cache_dir,
        )


if __name__ == "__main__":
    main()
