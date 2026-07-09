# MateMate ♟️

A chess platform in pure Swift: an iOS client, a shared chess engine package,
and a Vapor backend for realtime online play.

## Repository layout

| Directory | What it is |
| --- | --- |
| [`ChessKit/`](ChessKit) | Swift package with three libraries: **ChessKit** (board, legal moves, SAN, FEN, PGN, game state, post-game review), **ChessProtocol** (engine abstraction, negamax engine, UCI adapter), and **ChessOnline** (wire-protocol DTOs shared by app and server) |
| [`ios-chess-client/`](ios-chess-client) | SwiftUI app (iOS 17+): play the engine offline or people online |
| [`chess-server/`](chess-server) | Vapor backend: guest auth, matchmaking, realtime games over WebSockets, game history |

## Features

- **Play the engine** — four strengths (Beginner → Expert), driven by a small
  alpha-beta negamax search. Tap-to-move board with legal-move hints, last-move
  and check highlights, promotion picker, captured pieces and material count.
- **Play online** — guest account is created transparently on first use;
  FIFO matchmaking pairs you with the next player. The server validates every
  move; disconnected players get 60 seconds to reconnect before forfeiting.
- **Game review** — per-move judgments (best → blunder), Lichess-style
  accuracy, an evaluation graph, and full board playback. Every finished game
  (local or online) is saved on-device with SwiftData.

## Getting started

Play against the engine — nothing to set up:

```sh
open ios-chess-client/ios-chess-client.xcodeproj   # then Run
```

Play online locally — start the server first; Debug builds of the app point at
`127.0.0.1:8080` automatically:

```sh
cd chess-server
swift run App serve --hostname 127.0.0.1 --port 8080
```

Then tap **Play Online** in two simulators to match them against each other.

## Tests

```sh
cd ChessKit && swift test        # rules, SAN, engine, protocol coding
cd chess-server && swift test    # auth + full WebSocket match integration
```

The app's UI test suite includes a true end-to-end online match: the test
process registers its own guest account, queues over a WebSocket, and plays
engine moves against the app running in the simulator (skipped when the local
server isn't running).

## Architecture notes

- The **server is authoritative**: clients mirror the game locally for SAN and
  highlights, but every move is legality-checked server-side with ChessKit
  before being broadcast.
- The **wire protocol** (`ChessOnline`) is a single source of truth compiled
  into both the app and the server — type-discriminated JSON over one
  WebSocket per player.
- **Auth** is password-less but production-hardened: a rotating 32-byte
  refresh token (stored hashed server-side, kept in the iOS Keychain) is the
  account credential; access tokens are 1-hour JWTs. See the
  [server README](chess-server/README.md) for the token model and deployment
  (Postgres, `JWT_SECRET`, Docker).
