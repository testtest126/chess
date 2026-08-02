---
name: claim-issue
description: Safely claim a GitHub issue in the multi-session chess repo — dedupe against existing claims, PRs, branches, and worktrees, post the claim comment, and cut an isolated worktree off origin/main. Use before starting ANY issue.
---

# Claim an issue

Argument: issue number. AGENTS.md rules 1–3 apply; this skill is their
mechanical form.

## Dedupe first — all four checks, in one batch

```bash
gh issue view <N> --comments        # unresolved claim comment = owned, stop
gh pr list --state all | grep -i <topic>   # open OR merged PR = done/owned
git fetch origin --prune && git branch -a | grep -i <topic>
git worktree list                   # locked wt or fresh-mtime changes = owned
```

If ANY check shows an incumbent: stop, report who owns it, and pick different
work. Do not start a "better" parallel implementation — this repo lost hours
to duplicates (#62 duplicated #66; three sessions once held rematch-decline
fixes simultaneously).

## Claim and cut the worktree

```bash
gh issue comment <N> --body "Claimed — <your session title>, $(date +%Y-%m-%d)"
git worktree add .Codex/worktrees/<slug> -b feature/<slug> origin/main
```

- Branch off `origin/main` only (fetch first). Never branch off another
  feature branch without that owner's consent.
- If the branch name is taken, pick another name — never force.
- GitHub unreachable? Claims are invisible in both directions: assume you may
  be duplicating, keep work local, and re-run the dedupe checks the moment
  connectivity returns — before pushing or opening a PR.

## Abandoning

If you stop before finishing: delete the branch and worktree, and comment the
retraction on the issue. Empty just-in-case branches read as claims to other
sessions — don't leave claim-lint.
