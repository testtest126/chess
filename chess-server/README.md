# chess-server

Vapor backend for the MateMate iOS client: guest accounts, realtime online
matchmaking and play over WebSockets, and finished-game history. The server is
authoritative — every move is validated with ChessKit before it is accepted.

## Endpoints

| Route | Description |
| --- | --- |
| `POST /auth/register` | Create a guest account, returns access + refresh tokens |
| `POST /auth/refresh` | Rotate the refresh token, mint a new access token |
| `GET /me`, `PATCH /me` | Fetch / rename the authenticated user |
| `DELETE /me` | Delete the account: user + refresh tokens removed, game records anonymized |
| `GET /games`, `GET /games/:id` | The caller's finished games |
| `GET /leaderboard` | Top 50 players by Elo (players with at least one finished game) |
| `WS /play` | Realtime protocol (see `ChessOnline` target in ../ChessKit) |

All routes except `/auth/*` and `/health` require `Authorization: Bearer <access token>`.

## Auth model

Guest accounts are password-less but production-hardened:

- The **refresh token** (32 random bytes) is the account credential. It is
  returned exactly once per rotation; only its SHA-256 digest is stored.
  The iOS client keeps it in the Keychain.
- Refresh tokens **rotate on every use** and expire after 90 days of disuse;
  a replayed old token is rejected.
- **Access tokens** are HS256 JWTs valid for 1 hour, signed with `JWT_SECRET`.

Sign in with Apple can be layered on later for account recovery without
changing this token model.

## Running locally

```sh
swift run App serve --hostname 127.0.0.1 --port 8080
```

Development mode uses a local SQLite file and an insecure JWT key (with a
warning). Tests: `swift test`.

## Production

Required environment:

- `JWT_SECRET` — long random string; the server refuses to boot without it.
- `DATABASE_URL` — `postgres://user:pass@host:5432/db`.

Deploy behind TLS (the client must use `https`/`wss`). Build the container
from the repository root so the local ChessKit dependency is in context:

```sh
docker build -f chess-server/Dockerfile -t chess-server .
```

### Fly.io

`fly.toml` at the repository root describes the zero-spend production
deployment: one shared-cpu machine that stops when idle, SQLite on a small
volume (no Postgres), shared IPs, health-checked on `/health`, TLS
terminated by Fly. From the repo root:

```sh
fly volumes create matemate_data --size 1              # SQLite lives here
fly secrets set JWT_SECRET=$(openssl rand -hex 32)
fly secrets set SIWA_APP_ID=se.kovalskyi.matemate   # enables /auth/apple
fly deploy
fly scale count 1
```

Exactly one machine, always: live games, matchmaking queues, and rematch
offers are in-process state, so the server cannot scale horizontally. Idle
auto-stop is safe — that state only matters while sockets are open, and Fly
does not stop machines with live connections. Migrations run at boot.
Release builds of the iOS app point here via `ServerConfig.swift`.

## Realtime protocol

JSON messages defined in `ChessKit/Sources/ChessOnline` and shared with the
client. Client sends `join_queue` / `leave_queue` / `move` / `resign` /
`offer_draw` / `accept_draw` / `decline_draw`; server sends `queued`,
`game_start` (also used for reconnect resync), `move_played`, `game_over`,
`draw_offered`, `draw_declined`, `opponent_status`, and `error`.

- **Matchmaking** is FIFO per time control (only players who asked for the
  same control are paired), with random color assignment.
- **Time controls**: `join_queue` names one of `bullet` (1+0), `blitz` (5+3),
  or `rapid` (10+5); a missing field means blitz, the fixed control that
  predates the picker. Clocks are enforced server-side; `game_start` echoes
  the control and both remaining clocks, every `move_played` carries both
  clocks, and a fallen flag ends the game with reason `timeout`. Rematches
  reuse the finished game's control; an offer that isn't agreed within 60
  seconds of game end expires, and both players get `rematch_unavailable`.
- **Draw offers** stay on the table until answered or either side moves.
- **Ratings**: every user starts at Elo 1200; finished games (including
  timeouts and abandonments) are rated with K=32. Deltas ride along on
  `game_over`, and `GET /me` reports the current rating.
- A disconnected player has 60 seconds to reconnect before forfeiting by
  abandonment (the chess clock keeps running regardless).
