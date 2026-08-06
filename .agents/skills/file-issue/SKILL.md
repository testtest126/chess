---
name: file-issue
description: File a GitHub issue in the chess repo without duplicating the fast-moving backlog — search open AND closed issues and PRs first, then file with the repo's label conventions (bug/enhancement + ios/server/engine). Use before filing any issue, discussion, or bug report.
---

# File an issue

## Dedupe first (AGENTS.md rule 6)

```bash
gh issue list --state all --search "<keywords>" --limit 20
gh pr list --state all --search "<keywords>" --limit 20
```

The backlog moves fast: a fix may already exist as a merged PR with no issue,
or as an open draft (#62 duplicated already-merged #66 during an outage).
Search more than one keyword — symptom AND component. Near-duplicate found?
Comment there instead of filing.

## File

```bash
gh issue create \
  --title "<area>: <symptom or goal>" \
  --label <bug|enhancement|documentation|question> \
  --label <ios|server|engine>
```

- Two labels: type (`bug`/`enhancement`/`documentation`/`question`) + area
  (`ios`/`server`/`engine`; `dependencies` for dep bumps). Multi-area issues
  take multiple area labels (#45 carries three).
- Title style in this repo is `area: concrete statement` — say the symptom or
  the goal, not "problem with X".
- Body: evidence over narrative — SHAs, exact error output, repro commands,
  and what "done" looks like. Timestamp claims about mutable state.

## After filing

- Filing is NOT claiming. Work starts with `/claim-issue`; an issue you filed
  is as free for others as any other.
- A new **security** issue re-arms the rule-7 deployment gate on #28 —
  message the orchestrator when you open one.
