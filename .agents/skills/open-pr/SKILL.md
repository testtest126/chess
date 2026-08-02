---
name: open-pr
description: Package a finished worktree branch into a PR and hand it to the orchestrator for merging — pre-push checks, correct flags (draft for security-sensitive), and a merge-request message that survives crossing in flight. Use when a branch is ready for review, or when asked to "open a PR" / "request merge".
---

# Open a PR and request merge

You do not merge it. You do not arm auto-merge — arming counts as merging
(AGENTS.md rule 4; #60 merged past a block exactly this way).

## Before pushing

1. `/verify-at-head` at your exact tip — all three legs, truthful exit codes.
2. If GitHub was unreachable at claim time, re-run the four dedupe checks now
   (`/claim-issue` lists them) — before pushing, not after.
3. Classify the diff with `/security-gate`. Security-sensitive → the PR opens
   as **draft** and stays draft until the root agent approves.

## Open

```bash
git push -u origin <branch>
gh pr create --title "<what it does> (closes #N)" --body "..." [--draft]
```

Body must contain: `Closes #N`; what you verified locally (which suites, exit
codes, at which SHA); whether the diff is security-sensitive; whether it
touches the app (iOS lane gate applies); whether it touches shared files —
especially `ChessKit/Sources/ChessOnline/Messages.swift`, which the
orchestrator sequences.

## Request merge from the orchestrator

Messages cross in flight — state immutable facts, not "it's green now":

```
Merge request: PR #<N> @ <head-sha>
Verified locally: ChessKit EXIT:0, server EXIT:0, iOS build EXIT:0 @ <sha>
Security-sensitive: no | yes (draft, awaiting APPROVE)
App-touching: no | yes
Shared files: none | Messages.swift (sequence me)
```

Send via `mcp__ccd_session_mgmt__send_message` to the orchestrator session
(find it with `list_sessions`). Messaging down? Post the same text as a PR
comment — durable repo-side artifacts are the fallback channel.

## After

- Any new push voids CI results the orchestrator saw AND any security
  verdict. Re-request with the new head SHA; don't assume the old request
  carries over.
- Resolve every review thread — conversation resolution is a hard merge gate.
- Silence is never approval. No response ≠ merged; check the PR state, not
  your memory.
