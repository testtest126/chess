You are CONTINUING A PREVIOUS SESSION's work on the chess monorepo at
/Users/yk/dev/chess (ChessKit + chess-server + ios-chess-client). Several
sessions work here concurrently and the repo has moved since your predecessor
stopped — your context is STALE BY DEFAULT. Read CLAUDE.md at the repo root
first; it is binding.

PREVIOUS SCOPE (fill in):
- Issue/topic:  <#N — short description>
- Branch:       <feature/...>
- Worktree:     <.claude/worktrees/... or "main checkout — verify you are
                 still the designated single writer in CLAUDE.md">
- Last known state: <e.g. "tests green locally, PR not yet opened">

RECONSTRUCT BEFORE RESUMING — evidence over memory, in this order:
1. git fetch origin --prune, then compare: does your branch still exist? What
   does `git log origin/main --oneline -15` show — did your work (or someone
   else's version of it) ALREADY LAND? Sessions here inherit each other's file
   states; never re-apply a fix without checking whether HEAD already has it.
2. `gh pr list --state all` + the issue's comments: is there a newer claim, an
   open PR, or a merge that supersedes you? If someone else now owns the issue,
   stop and message the "Agent orchestration and spawning" session instead of
   resuming.
3. `git status` in your worktree: uncommitted changes are yours to salvage —
   but diff them against current origin/main before assuming they're still
   needed.
4. Check the shared task board (TaskList) and update your task's status/owner
   to reflect reality before writing code.

THEN RESUME under the standing rules:
- Work only in your worktree; never edit/build/switch branches in the main
  checkout unless CLAUDE.md currently names you the single writer.
- Rebase onto latest origin/main before finishing; re-run ALL verification on
  the rebased branch: swift test in ChessKit/ and chess-server/, and
  xcodebuild build -scheme ios-chess-client
    -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.5'
- Ship complete vertical slices only — a new protocol enum case needs Kind
  mapping, encode AND decode arms, coordinator handling, iOS handling, and
  round-trip tests before it is committed anywhere.
- PRs: target main, "Closes #N", generated-with footer. You never merge;
  security-sensitive diffs stay draft until "Security review: APPROVE @ <sha>".
- If git state contradicts your expectations mid-task (branch switched, file
  changed under you, edit rejected), stop and re-reconstruct — don't retry
  blindly.

Report your reconstruction findings (what landed, what's stale, what remains)
BEFORE making changes, so the resumption plan is visible and correctable.
