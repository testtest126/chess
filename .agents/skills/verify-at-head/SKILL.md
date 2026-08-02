---
name: verify-at-head
description: Verify the chess repo builds and tests green at an exact commit or PR head, in a detached scratch worktree — never in the shared main checkout. Use before endorsing, reviewing, requesting merge of, or basing new work on any commit.
---

# Verify at exact head

Argument: a commit SHA, or a PR number (resolve with
`gh pr view N --json headRefOid -q .headRefOid`; fetch the ref first if needed:
`git fetch origin <headRefName>`).

## Steps

1. Scratch worktree at the EXACT sha — never verify in `/Users/yk/dev/chess`
   (another session can switch its branch mid-run):
   ```bash
   git worktree add "$SCRATCHPAD/verify-<sha7>" <sha> --detach
   ```
2. All three legs, each with truthful exit codes — `$?` after a pipe reports
   the LAST command (tail), so set pipefail first:
   ```bash
   cd <wt>/ChessKit      && set -o pipefail && swift test 2>&1 | tail -6; echo "EXIT:$?"
   cd <wt>/chess-server  && set -o pipefail && swift test 2>&1 | tail -6; echo "EXIT:$?"
   cd <wt>/ios-chess-client && set -o pipefail && xcodebuild build \
     -scheme ios-chess-client \
     -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.5' -quiet 2>&1 | tail -6; echo "EXIT:$?"
   ```
   The `OS=17.5` pin is required on this machine: bare `name=iPhone 15`
   resolves OS:latest and fails.
3. Clean up: `git worktree remove --force "$SCRATCHPAD/verify-<sha7>"`.

## Gotchas

- SwiftPM prints a bare `error: fatalError` trailer on build failure — that is
  NOT the diagnostic. Grep the full output for the real `error:` line
  (e.g. `swift build 2>&1 | grep -B2 'error:'`).
- Verifying a PR head is not verifying the merge result. If main moved since
  the PR branched, also verify the merge state (`git merge-base` +
  test the PR's merge ref, or after update-branch) — two individually-green
  PRs have combined into a broken main here before (#54 + #55).
- Run the suites in the background for long builds; report exact tails and
  exit codes, never "looked fine".
