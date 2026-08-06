---
name: merge-pr
description: Orchestrator-only merge gate — identity check, green-on-CURRENT-merge-state verification, review-thread resolution, iOS lane for app-touching PRs, security verdict at exact head, orchestrator-approval status, then the merge. Use only if you are the orchestrator session; workers use /open-pr to request a merge instead.
---

# Merge a PR (orchestrator only)

## 0. Confirm you ARE the orchestrator

Two sessions once held the merger role simultaneously (2026-07-11 bootstrap
fan-out). Before acting as merger: `list_sessions` for another live
orchestrator, and transcript-search if ambiguous. If in doubt, you are not
the merger — message the session that is.

## 1. Gates — all evaluated at the CURRENT merge state

```bash
gh pr view <N> --json headRefOid,isDraft,mergeStateStatus,files,reviewDecision
gh pr checks <N>
```

- **Stale green:** a green run from before another PR merged proves nothing.
  If main moved since the run: `gh pr update-branch <N>`, wait for fresh
  checks. #54 + #55 were individually green and combined uncompilable.
- **Shared files** (especially `ChessKit/Sources/ChessOnline/Messages.swift`):
  merge one at a time, re-verify the next against the new main before
  merging it.
- **Review threads:** every one resolved (branch protection enforces it —
  do not resolve someone else's thread to unblock yourself).
- **App-touching:** the `iOS` workflow must be green at this head. It is NOT
  a required check — verify manually (`gh run list --workflow iOS`); ignoring
  it shipped #68.
- **Security-sensitive (rule 5):** still draft? Not mergeable. Undrafted?
  Confirm `Security review: APPROVE @ <head-sha>` exists at the EXACT current
  head — a new push voids the verdict. Re-check immediately before merging,
  not from memory of an earlier sweep.

## 2. Approve and merge

Only after every gate above, post the required status at the exact head:

```bash
gh api repos/testtest126/chess/statuses/<head-sha> \
  -f state=success -f context=orchestrator-approval \
  -f description="All gates verified @ <head-sha7>"
gh pr merge <N> --squash
```

- A timed-out merge PUT can still land server-side. On timeout: re-check
  `gh pr view <N> --json state,mergedAt` before retrying — do not double-act.
- Native auto-merge is the only sanctioned automation, and only you arm it.
  No custom merge-on-green loops.
- After each merge, the queue restarts: the next PR's green is now stale by
  definition — re-run its gates against the new main.
