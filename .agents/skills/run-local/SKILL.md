---
name: run-local
description: Build and run the MateMate stack locally — chess-server on 127.0.0.1:8080, package test suites, the iOS app in a simulator (two simulators for online play). Use when asked to run, try, demo, or reproduce behavior in the app or server.
---

# Run the stack locally

Rule 1 applies to running too: `swift run`/`swift test`/`xcodebuild` all
BUILD, and building in the shared main checkout collides with other sessions.
Run from your own worktree (or a detached scratch worktree via
`/verify-at-head` for a specific head).

## Server

Never run servers via Bash — use the Browser pane. The main checkout defines
a `chess-server` launch config (`.Codex/launch.json`); `.Codex/` is
gitignored, so a fresh worktree has none. Copy it in once, then start:

```bash
mkdir -p <worktree>/.Codex && cp /Users/yk/dev/chess/.Codex/launch.json <worktree>/.Codex/
```

Then `preview_start` with name `chess-server` → serves on `127.0.0.1:8080`.
Check `preview_logs` for the Vapor startup line before poking it.

## Tests (the two CI lanes)

```bash
swift test --package-path ChessKit       # "ChessKit tests" lane
swift test --package-path chess-server   # "Server tests" lane
```

## iOS app

```bash
xcodebuild -project ios-chess-client/ios-chess-client.xcodeproj \
  -scheme ios-chess-client \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.5' build
```

The `OS=17.5` pin is required on this machine — bare `name=iPhone 15`
resolves OS:latest and fails. Debug builds talk to `127.0.0.1:8080`
automatically; for online play, boot the server and launch the app in TWO
simulators.

## Invariants to not break while poking around

- The engine is deterministic by design (fixed-seed Zobrist; randomness only
  via the opening book). Several tests rely on it.
- The server is authoritative for online play — if a "fix" makes the client
  decide legality, clocks, or results, it's a bug.
- Local dev databases are `*.sqlite` files, gitignored — deleting one resets
  local accounts/games; fine for you, but say so if reporting behavior.
