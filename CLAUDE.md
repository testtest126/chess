# Multi-agent coordination rules

Several Claude sessions work on this repo concurrently. Follow these rules to avoid collisions:

1. **Do not edit, build, or switch branches in the main checkout** (`/Users/yk/dev/chess`) unless you are the designated single writer (see below). For all other work, create an isolated worktree:
   `git worktree add .claude/worktrees/<name> -b <branch> origin/main`
2. **Claim before you build.** Before starting a GitHub issue, comment `Claimed — <your session title>, <date>` on it and check that no unresolved claim comment already exists. Unclaimed issues are free; claimed ones are not.
3. **Branch off `origin/main`**, never off another feature branch, unless deliberately stacking with that branch owner's consent.
4. **Merging.** The **orchestration session is the only merger** — no session merges any PR, including its own, no matter how green. Request a merge by messaging the orchestrator. It merges only when (a) required checks are green on the **current** merge state — a green run from before another PR merged is stale and gets re-run via update-branch; PRs touching shared files (especially `ChessKit/Sources/ChessOnline/Messages.swift`) are sequenced and re-verified between merges — (b) every review thread is resolved, and (c) for app-touching PRs, the path-filtered `iOS` workflow is green too (it is not a required check; the orchestrator verifies it manually). No custom merge-on-green loops by anyone; the only sanctioned automation is GitHub's native auto-merge, armed by the orchestrator. Branch protection on `main` (green `ChessKit tests` + `Server tests`, conversation resolution, admins included) stays ON — do not work around it.
5. **Security-sensitive code** (auth, token verification, crypto, account linking, session management): the PR opens as a **draft** and stays draft until the root agent session posts a review verdict comment on the PR: `Security review: APPROVE @ <head-sha>` — at the exact head being merged; silence is never approval. A BLOCK is posted as **line-level review comments** (these gate merging mechanically via conversation resolution) plus a summary comment, and halts everything until re-review. History: this rule exists because an HMAC-verified "Apple" token forgery (PR #50) and its fix (PR #57) were both merged past a pending review.
6. **Duplicates:** before filing an issue/discussion or starting a fix, search open issues and PRs; the backlog moves fast here.
7. **Deployment gate:** issue #28 (public deployment) must not proceed while any open security issue (currently #56) is unresolved.

**Current single writer of the main checkout:** none — the checkout is idle. Ask the orchestrator session before taking it; default to a worktree.

To coordinate or dispute ownership, message the orchestrator session via `mcp__ccd_session_mgmt__send_message` (find it with `list_sessions`; it maintains the assignment map) rather than editing contested files.
