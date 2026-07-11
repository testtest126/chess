# Agent session interaction guide

How the concurrent Claude sessions working on this repo coordinate. CLAUDE.md
holds the binding rules; this guide is the operating manual — how to follow
them without colliding, with templates and the incidents that shaped them.
All examples date from 2026-07-10, the day this fleet scaled from two sessions
to nine.

## Roles

- **Orchestrator session** — owns the assignment map and merge authority.
  Maintains CLAUDE.md, sequences the merge queue, posts the
  `orchestrator-approval` required status. Ask it before taking contested
  resources; route merge requests to it.
- **Root agent session** — the named security reviewer (CLAUDE.md rule 5) and
  independent verifier. Runs monitoring sweeps; flags red lanes and unowned
  breakage.
- **Worker sessions** — implement issues in isolated worktrees, one issue at a
  time, claimed before started.

## Starting work

1. Run `/claim-issue` (or manually: check the issue for claim comments, open
   PRs, matching branches, and locked worktrees — all four, not just one).
2. Comment `Claimed — <session title>, <date>` on the issue.
3. `git worktree add .claude/worktrees/<name> -b <branch> origin/main` — never
   branch off another feature branch without its owner's consent, never work
   in the main checkout unless you are its designated single writer.
4. If you find the issue mid-implemented by someone else: stop, message the
   orchestrator, and let it rule. Do not "finish" another session's tree.

## Communicating

- Messages between sessions **cross in flight** constantly. Write every status
  message so it survives crossing: state SHAs, PR numbers, and exact test
  counts; timestamp claims about mutable state; treat any instruction that
  contradicts fresher git evidence as stale and say so explicitly.
- **Silence is never consent.** If you need an approval, wait for the explicit
  artifact (message, PR comment, status check) — and re-check for it
  immediately before acting on it.
- **Attribute by evidence, not inference.** All sessions share one git/GitHub
  identity. "The commit appeared while session X was active" is not
  attribution. Check `git log --format='%h %ai %s'`, branch topology, and
  worktree paths before naming an actor; this fleet has had two
  misattribution incidents.
- When the session-messaging server is down, coordinate through durable
  repo-side artifacts: PR comments, issue comments, claim comments.

## Getting a PR merged

1. Verify at your exact head with `/verify-at-head` (detached scratch
   worktree; three legs: ChessKit tests, server tests, iOS build). A green
   run at your head is not a green run at the merge state — say which one
   you verified.
2. Push, open the PR (`Closes #N`), let CI run.
3. Request merge from the orchestrator with: PR number, head SHA, what you
   verified locally, and whether the diff is security-sensitive or
   app-touching.
4. The orchestrator merges when: required checks are green on the **current**
   merge state; every review thread is resolved; the path-filtered iOS lane is
   green for app-touching PRs (checked manually — it is not a required check);
   and it has posted the `orchestrator-approval` status at your exact head.
5. **Never merge, and never arm auto-merge — arming is merging.** Auto-merge
   fires on green without re-reading review comments; that is how a blocked
   security PR merged once. The orchestrator arms it, nobody else.

## Security-sensitive diffs

Auth, token verification, crypto, account linking, session management:

- Open the PR as **draft**. It stays draft until the root agent session posts
  `Security review: APPROVE @ <head-sha>` — at the exact head; a new push
  voids the verdict.
- BLOCK verdicts arrive as line-level review comments (they gate merging
  mechanically via required conversation resolution) plus a summary.
- Tests must be able to catch the class of bug under review: a test that
  signs its fixtures with the same key the code trusts proves nothing —
  that exact pattern shipped a token-forgery hole once (PR #50).

## Incident ledger (why each rule exists)

| Incident | Lesson encoded |
|---|---|
| Two sessions edited one checkout; a stub was overwritten silently | Worktrees + single-writer rule (rule 1) |
| #14 implemented twice in one tree; misattributed blame | Claims (rule 2), evidence-based attribution |
| PR #50 merged at a BLOCKed head; fix #57 merged past review too | Sole merger, draft-until-APPROVE, `orchestrator-approval` required check |
| #54 + #55 individually green, combined uncompilable (hotfix #65) | Green on *current* merge state; sequence shared-file PRs; re-verify between merges |
| #62 duplicated already-merged #66 during a GitHub outage | Four-way dedupe before starting (rule 6) |
| #60 merged via auto-merge armed by a non-orchestrator | Arming auto-merge counts as merging |
| Red iOS lane ignored because it is not a required check (#68) | Manual iOS-lane gate for app-touching PRs (rule 4c) |

## Conventions

### Tags & releases

- **Server:** tag the deployed state (`server-vN`) at each Fly deploy. Gives
  rollback anchors and makes prod state a checkable fact.
- **iOS:** tag every TestFlight submission (`ios-v1.0-bN` style) so the exact
  source of any build in users' hands is traceable.
- **ChessKit:** no tags — it is a local path dependency; semver would be
  ceremony with no consumer.
- **Tag creation is an owner/orchestrator act.** Worker sessions never create
  tags unprompted.

### Milestones over Projects

Use milestones for tracking (e.g. "TestFlight 1.0"). A Projects board would be
a second source of truth to keep synced, and this repo's queue is small and
fast-moving with an orchestrator-owned assignment map. Revisit Projects only if
the backlog regularly holds 15–20+ open items or more humans join.

### Wiki

Keep empty / disabled. Docs belong in `docs/` — reviewed, versioned with code,
cloned by every session. The wiki forks documentation away from all three
properties.

### Discussions

Keep as the direction log for open questions that are not yet actionable. When
a thread reaches a decision, **distill it into an issue or a `docs/` note and
link back** so decisions don't stay buried in conversation.

## Tooling

Project skills live in `.claude/skills/` and encode the above mechanically.
That directory is gitignored — the skills are machine-local, shared by every
session on this machine but not part of the repo. Prefer them over ad-hoc
equivalents:

- `/claim-issue` — safe claiming: four-way dedupe, claim comment, worktree
  cut off `origin/main`.
- `/fleet-status` — evidence-based status sweep of main, CI, PRs, issues,
  worktrees, and claim signals.
- `/verify-at-head` — build-and-test verification at an exact SHA in a
  detached scratch worktree.
- `/open-pr` — package a finished branch into a PR and request merge from
  the orchestrator (worker side of rule 4).
- `/merge-pr` — the orchestrator's merge-gate checklist: identity check,
  green on the current merge state, iOS lane, security verdict,
  `orchestrator-approval` (merger side of rule 4).
- `/security-gate` — rule 5 mechanics: classification, draft-until-APPROVE
  at the exact head, test independence.
- `/file-issue` — dedupe-first issue filing with the repo's label
  conventions (rule 6).
- `/review-pr` — repo-specific review checklist: wire-protocol
  compatibility, engine determinism, server authority, test adequacy.
- `/run-local` — run the server, test suites, and app from a worktree
  without building in the shared checkout.
