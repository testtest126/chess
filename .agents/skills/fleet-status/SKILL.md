---
name: fleet-status
description: Evidence-based status sweep of the chess repo fleet — main health, CI conclusions, open PRs, newest issues, worktrees, claim signals. Use when asked for fleet/agent/project status, before assigning or claiming work, or at the start of a monitoring iteration.
---

# Fleet status sweep

Run these, in one batch where possible. Evidence over memory: never report from
recollection of an earlier turn — this repo moves fast and several sessions
write concurrently.

```bash
git fetch origin --prune
git log --format='%h %ai | %s' -5 origin/main
gh run list --branch main --limit 6 --json workflowName,conclusion,headSha \
  -q '.[] | .workflowName + " | " + (.conclusion // "running") + " | " + .headSha[0:7]'
gh pr list --state open --limit 15
gh pr list --state merged --limit 5
gh issue list --state open --limit 15
git worktree list
git -C /Users/yk/dev/chess branch --show-current && git -C /Users/yk/dev/chess status --short
```

## Interpretation rules (learned the hard way, 2026-07-10)

- A `cancelled` conclusion on a main push run means that tip was NEVER tested
  (concurrency cancel-in-progress) — do not treat main as green; check the next
  completed run or verify locally.
- The iOS workflow is informational unless/until it is a required check —
  main's package checks green does not mean the app builds.
- Locked worktrees under `.Codex/worktrees/` = live agents. Uncommitted
  changes with fresh mtimes = active claim even without a lock.
- Issue ownership lives in claim comments: `gh issue view N --comments`.
- A worktree whose branch tip moved since your last sweep is actively worked;
  one unchanged for hours may be stalled — report it, don't assume.
- Report deltas against the previous sweep, not a full dump: merges, new
  red lanes, new unowned bugs, stalled workstreams, review-gate requests.
