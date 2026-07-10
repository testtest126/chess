# Multi-agent coordination rules

Several Claude sessions work on this repo concurrently. Follow these rules to avoid collisions:

1. **Do not edit, build, or switch branches in this main checkout** (`/Users/yk/dev/chess`) unless you are the designated single writer (see below). For all other work, create an isolated worktree:
   `git worktree add .claude/worktrees/<name> -b <branch> origin/main`
2. **Claim before you build.** Before starting a GitHub issue, comment `Claimed — <your session title>, <date>` on it and check that no unresolved claim comment already exists. Unclaimed issues are free; claimed ones are not.
3. **Branch off `origin/main`**, never off another feature branch, unless deliberately stacking with that branch owner's consent.
4. **PRs:** target `main`, reference the issue (`Closes #N`), squash-merge only when every check is green.
5. **Security-sensitive code** (auth, token verification, crypto, account linking): have a second session review the diff before the PR leaves draft.
6. **Duplicates:** before filing an issue/discussion or starting a fix, search open issues and PRs; the backlog moves fast here.

**Current single writer of the main checkout:** the "iOS client implementation" session, reconciling issue #14 on `feature/sign-in-with-apple` (PR #50, in draft pending a security fix — see the PR comment before touching it).

To coordinate or dispute ownership, message the orchestrator session via `mcp__ccd_session_mgmt__send_message` (find it with `list_sessions`; it maintains the assignment map) rather than editing contested files.
