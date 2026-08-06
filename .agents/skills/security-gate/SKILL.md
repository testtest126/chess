---
name: security-gate
description: AGENTS.md rule-5 flow for security-sensitive diffs (auth, token verification, crypto, account linking, session management) — classify the diff, keep the PR draft until "Security review: APPROVE @ <head-sha>", and demand tests that can actually catch the bug class. Use before opening any PR touching those areas, or when asked to security-review one.
---

# Security gate (AGENTS.md rule 5)

Exists because an HMAC-forged "Apple" token (PR #50) and its fix (#57) both
merged past a pending review. The gate is mechanical now; keep it that way.

## Does rule 5 apply?

Yes if the diff touches auth, token verification, crypto, account linking, or
session management — directly or through code they call. Rate limiting on
auth endpoints counts. When unsure, treat it as sensitive: underclassifying
is how #50 shipped; overclassifying costs one review.

## Worker side

- Open the PR as **draft**. It stays draft until the root agent session posts
  `Security review: APPROVE @ <head-sha>` — at the exact head being merged.
- Every push voids the verdict. Re-request review with the new SHA.
- Silence is never approval. A pending review halts the merge, not you asking
  twice.
- **Test independence:** tests must be able to catch the bug class under
  review. A test that signs its fixtures with the same key the code trusts
  proves nothing — that exact pattern shipped #50. Model to follow: PR #74
  verifies the live Apple path against a loopback JWKS instead.

## Reviewer side (root agent session only)

- APPROVE: comment `Security review: APPROVE @ <head-sha>` on the PR.
- BLOCK: line-level review comments (these gate the merge mechanically via
  required conversation resolution) **plus** a summary comment. A block halts
  everything until re-review.
- Verify at the exact head in a scratch worktree (`/verify-at-head`) — never
  endorse from reading the diff alone.

## Side effect: the deployment gate

Opening a new security issue re-arms rule 7 — public deployment (#28) halts
until it is resolved. If your finding creates one, flag the re-armed gate to
the orchestrator explicitly.
