# Orchestrator end-of-day state — 2026-07-10

Main tip: `ce28716` (#81, CI concurrency fix). Fleet stood down for the day.

## Resume-first actions (in order)
1. **Merge #75** (lane closer, closes #68) — rebased clean to `7e2f534`,
   orchestrator-approval posted; merge on green required checks. Re-verify the
   run postdates `ce28716`.
2. **Merge #80** (Fly deploy config) — approved `@5dbd52d`, updated to
   `e976f0d`; merge on full green INCLUDING `Server image builds` (not
   branch-required, so MANUAL merge — auto-merge stays disarmed). iOS lane red
   is #68-class (Root attributed via job log), classify-pass per rule 4(c).
   After #75 lands, update-branch #80 via API (it touches no workflow files).
3. **Deploy** — executor is the root/bootstrap session, from
   `.fleet/deployment-runbook.md`, post-#80-merge main only. Zero-spend
   posture; rotate JWT_SECRET first; `fly volumes create matemate_data --size 1`
   (+$0.15/mo). Log every fly mutation on issue #28. Fly state at pause:
   app `matemate-chess`, zero machines/IPs/volumes, one staged JWT_SECRET.
4. **#78 security verdict** — DO NOT MERGE until a root-agent session posts
   `Security review: APPROVE @ 5533658` (or its successor head). Root cleared
   `a2809a6` interim (TOCTOU fix correct) but the head moved to `5533658`,
   which is UNREVIEWED. Rule 5 needs APPROVE at the exact merge head.

## Merge queue after #75/#80 (all base e910231 unless noted)
- App-touching wave (hold until #75's lane is green on main):
  #88/#91/#92/#93 (a11y A–D), #90 (icon — NEEDS USER VISUAL SIGN-OFF),
  Swift 6 stack #84→#85→#87 (strict order, stacked).
- #76 (macos-26, closes #44): CODE PROVEN (glass compiles under Xcode 26;
  resign-dialog selector fix `1cb48d6` passes both GameFlow tests locally on
  iOS 26.5) but the CI run HUNG ~45min and was cancelled at job timeout (no
  xcresult) — runner-environment issue, NOT functional. Prime suspect:
  OnlineMatchUITests not skipping cleanly on macos-26, or sim boot time. NOT
  merge-ready; shake out the runner first (diagnosis on the PR). Do not
  retry-merge expecting green.
- #75/#76 rebases must be done LOCALLY by authors — API token lacks
  `workflow` scope for `.github/workflows/*`.
- #86 closes as superseded when #80 lands. #94 (a11y audit harness) draft.
- #59 (CI E2E boot) STALLED >4h — user to decide keep/park; overlaps #80's
  TEST_RUNNER_CHESS_SERVER_URL.

## Gates in force (CLAUDE.md v2 + charter)
- Orchestrator is sole merger; `orchestrator-approval` required status check.
- Branch protection: ChessKit + Server tests + orchestrator-approval +
  conversation resolution + enforce_admins.
- Security PRs draft until root's `Security review: APPROVE @ <head>`.
- Deployment gated on open security issues (none open) + zero-spend.

## Open user decisions (non-blocking)
- #90 icon rebrand — visual sign-off.
- #59 — keep or park.
- #14 SIWA end-to-end — Apple team/bundle ID, capability, SIWA_APP_ID.

## Incident record (process, for the retro)
- Two premature merges (#50 blocked-head, #57) → mechanical `orchestrator-approval` gate.
- #54+#55 individually-green → uncompilable main (hotfix #65) → merge-state rule.
- Phantom Postgres cluster: created by iOS-client `fly postgres attach`
  (good-faith, believed user-directed); destroyed by root before its own
  consult window (self-recorded "right action, broken process").
- Multiple identity/attribution corrections resolved by SHA/log evidence, not inference.
