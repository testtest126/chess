# .fleet — bootstrap kit for the chess multi-session fleet

Created 2026-07-10 by the root agent session at the user's request. Everything
needed to spin the fleet back up and continue development at any time.

## Bootstrap order

1. **Read the repo's `CLAUDE.md`** — the binding coordination rules (worktree
   discipline, claim-before-build, orchestrator-only merges, rule-5 security
   review gate). It is maintained by the orchestrator session.
2. **Open session tabs and paste the matching prompt from `prompts/`:**
   - `root-agent.md` — orchestrator/verifier/security-reviewer (this session's role)
   - `orchestrator.md` — assignment map + sole merge authority
   - `ios-developer-onboarding.md` — one per feature-developer session
   - `continue-previous-session.md` — resuming any stopped session (fill the placeholders)
3. **Check `STATE-<date>.md`** (newest) for where work stopped: open PRs,
   verdict queue, and any mid-flight sequence with its exact next commands.
4. **Project skills** live in `.claude/skills/` (fleet-status, verify-at-head,
   claim-issue) — available to every session from this root automatically.
5. **Persistent memory** lives at
   `~/.claude/projects/-Users-yk-dev-chess/memory/` — auto-loaded per session;
   `multi-session-repo-coordination.md` is the accumulated incident wisdom,
   `flyio-deployment-platform.md` the hosting decisions.

## Standing facts

- **Coordination:** shared task board (TaskList) + cross-session messages
  (`send_message` has standing user approval). The orchestrator session owns
  merging; nobody else merges, ever. Security-sensitive diffs need a
  "Security review: APPROVE @ <head>" comment from the root agent session.
- **Hosting:** Fly.io (personal org, billing configured).
  App `matemate-chess`. Zero-spend posture is user policy — see
  `deployment-runbook.md`. Every fly mutation gets logged as a comment on
  issue #28 with the exact command and expected monthly cost.
- **Monitoring cadence:** ~25 min heartbeat via `/loop monitor the chess repo
  fleet status (self-paced)`; tighten only during incidents.
- This folder is git-excluded locally (`.git/info/exclude`). If it should be
  versioned, any session can PR it per the normal flow.
