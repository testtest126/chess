# Fly.io deployment runbook — chess-server (zero-spend posture)

User policy: no meaningful spend. Fly PAYG has NO free tier and NO invoice
waiver (verified against live pricing docs 2026-07-10) — the floor is cents,
not $0.00. Approved posture ("cents"): single shared-cpu-1x 256MB machine,
auto_stop/min=0, shared IPs only (NEVER `fly ips allocate-v4` — dedicated v4
is $2/mo), SQLite on a 1GB volume ($0.15/mo), no Postgres. Expected total
**< $0.40/mo**.

Every mutation gets a comment on issue #28: exact command + expected monthly
cost. This substitutes for the orchestrator's spend gate (agreed terms).

## Sequence (from post-#80-merge main; do NOT deploy a pre-merge tree)

```bash
cd /Users/yk/dev/chess && git pull --ff-only origin main   # fly.toml + fixed Dockerfile arrive tracked
fly auth whoami                                            # expect your Fly account email
fly apps list                                              # expect matemate-chess only, no machines
fly secrets set "JWT_SECRET=$(openssl rand -hex 32)" -a matemate-chess   # rotation (on record)
fly volumes create matemate_data --size 1 --region waw -a matemate-chess # +$0.15/mo — log on #28
fly deploy --remote-only --yes                             # config = tracked fly.toml at repo root
```

## Verify (log results on #28)

```bash
fly machines list -a matemate-chess    # exactly ONE machine, shared-cpu-1x:256MB
fly ips list -a matemate-chess         # shared v4 + dedicated v6 ONLY
fly volumes list -a matemate-chess     # one 1GB volume
curl -s https://matemate-chess.fly.dev/health          # "ok"
curl -s https://matemate-chess.fly.dev/leaderboard     # JSON
# auto-stop check: after ~10 idle minutes the machine shows "stopped"
```

## Hard-learned gotchas

- flyctl resolves `dockerfile` relative to the CONFIG FILE (even absolute
  paths get mangled) — keep fly.toml at the build-context root.
- Without the repo-root `.dockerignore` the context is ~21GB of worktrees.
- The Dockerfile must be swift:6.0+ (jwt 5.x needs tools 6.0) with
  `--static-swift-stdlib` (bare-ubuntu run stage has no Swift runtime).
- A staged `DATABASE_URL` overrides SQLITE_PATH at boot (configure.swift
  precedence) — make sure it is UNSET unless Postgres is intended.
- `TRUST_PROXY_HEADERS=true` must be set (it is, in fly.toml [env]) or the
  auth limiter buckets all users as one client behind fly-proxy.
- SIWA_APP_ID unset ⇒ /auth/apple returns 503 by design.

## Post-deploy

- Inventory + exact monthly figure on #28 (closes the executor loop).
- PR #78 @ 5533658 security verdict is next in the queue.
- If anything must change in fly.toml/Dockerfile: through the PR flow, never
  by editing tracked files in the main checkout.
