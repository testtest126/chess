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
| `GET /games`, `GET /games/:id` | The caller's finished games |
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

## Realtime protocol

JSON messages defined in `ChessKit/Sources/ChessOnline` and shared with the
client. Client sends `join_queue` / `leave_queue` / `move` / `resign` /
`offer_draw` / `accept_draw` / `decline_draw`; server sends `queued`,
`game_start` (also used for reconnect resync), `move_played`, `game_over`,
`draw_offered`, `draw_declined`, `opponent_status`, and `error`.

- **Matchmaking** is FIFO with random color assignment.
- **Time control** is 5 minutes + 3 seconds increment, enforced server-side;
  `game_start` and every `move_played` carry both remaining clocks, and a
  fallen flag ends the game with reason `timeout`.
- **Draw offers** stay on the table until answered or either side moves.
- **Ratings**: every user starts at Elo 1200; finished games (including
  timeouts and abandonments) are rated with K=32. Deltas ride along on
  `game_over`, and `GET /me` reports the current rating.
- A disconnected player has 60 seconds to reconnect before forfeiting by
  abandonment (the chess clock keeps running regardless).
