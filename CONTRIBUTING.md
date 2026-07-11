# Contributing to MateMate

Thanks for taking a look! This is a small, friendly codebase — a good place
to make your first open-source chess contribution.

## Getting set up

You need a Mac with Xcode 15 or newer (iOS 17 SDK). Everything else is Swift
Package Manager — no other tooling.

```sh
git clone https://github.com/testtest126/chess.git
cd chess

# The engine & rules library
swift test --package-path ChessKit

# The multiplayer server
swift test --package-path chess-server

# The app
open ios-chess-client/ios-chess-client.xcodeproj   # then Cmd-R
```

To try online play locally, run the server and launch the app in two
simulators (Debug builds talk to `127.0.0.1:8080` automatically):

```sh
swift run --package-path chess-server App serve --hostname 127.0.0.1 --port 8080
```

## Where things live

| Path | What it is |
| --- | --- |
| `ChessKit/Sources/ChessKit` | Rules: board, legal moves, SAN/FEN/PGN, game state, review |
| `ChessKit/Sources/ChessProtocol` | Engine: negamax search, opening book, UCI adapter |
| `ChessKit/Sources/ChessOnline` | Wire protocol shared by app and server |
| `chess-server/Sources/App` | Vapor server: auth, matchmaking, clocks, ratings |
| `ios-chess-client` | SwiftUI app |

## Ground rules

- **Tests**: rules/engine/server changes need tests. The engine is
  deterministic by design (fixed-seed Zobrist, no randomness without an
  opening book) — please keep it that way, several tests rely on it.
- **The server is authoritative** for online play. Never trust the client
  with legality, clocks, or results.
- **CI** runs both package suites on every PR; it must be green.
- Match the style around you; `swiftformat .` enforces it mechanically
  (config in `.swiftformat`), and a small curated SwiftLint rule set
  (`.swiftlint.yml`, warnings-only) flags force-unwraps and similar in
  production code. CI's `Lint` job runs both in check mode. Keep comments
  for things the code can't say.

## Finding something to work on

Issues labeled [`good first issue`](https://github.com/testtest126/chess/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)
are scoped to be approachable without knowing the whole codebase. Comment on
an issue before starting so work doesn't get duplicated.
