---
name: review-pr
description: Chess-repo-specific review checklist for a PR — wire-protocol compatibility, engine determinism, server authority, security classification, and test adequacy. Use when reviewing any PR in this repo; run alongside the generic /code-review skill, which hunts generic bugs.
---

# Review a PR (repo-specific checks)

Generic correctness bugs: `/code-review` finds those. This checklist is what
is specific to THIS codebase — check every item, then verify.

## Cross-cutting invariants

- **Wire protocol** (`ChessKit/Sources/ChessOnline/Messages.swift`): shared
  by app and server, both must move together. Old clients hit new servers —
  changes must be additive/tolerant. Any PR touching it needs the
  orchestrator to sequence its merge; confirm the PR body flags this.
- **Server is authoritative** for online play. Reject anything that lets the
  client decide legality, clocks, or results — even "just for
  responsiveness".
- **Engine determinism**: fixed-seed Zobrist, no randomness outside the
  opening book. New `random`/`Date()`/hash-ordering dependence in
  ChessKit/ChessProtocol will break tests that rely on determinism.
- **Rate limiting / abuse surface** (server): new endpoints follow the
  patterns from #32 (auth rate limits, guest reaping) — an unlimited new
  endpoint is a finding.

## Process gates

- **Security classification**: auth / token verification / crypto / account
  linking / session management → must be a draft under `/security-gate`. A
  non-draft PR touching those is itself the first finding.
- **Tests catch the bug class**: a test that signs fixtures with the key the
  code trusts proves nothing (#50). Ask: "if the bug were reintroduced,
  would this suite go red?"
- **App-touching?** The `iOS` lane must be green — it is not a required
  check, so look at it explicitly (`gh run list --workflow iOS`).

## Verdict discipline

- Verify at the exact head in a scratch worktree (`/verify-at-head`) before
  endorsing — never from the diff alone, and never in the main checkout.
- State which SHA you reviewed and which SHA you verified; a new push voids
  both.
- Blocking findings go as line-level review comments (they gate the merge
  via required conversation resolution), plus a summary.
