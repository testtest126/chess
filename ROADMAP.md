# MateMate — Roadmap

## Now
- Merge #186 (CI permissions) and #187 (security headers).
- Review and approve #185 (Postgres sliding-window rate limiter) at the `Security review: APPROVE @ <sha>` gate.
- Run the Screenshots workflow.

## Next
- Ship the single-instance launch (#28) — the milestone the rate-limiter work was gating for.
- Polish post-game analysis.

## Later
- Shared-store rate limiter — #182 (Postgres) merged, with #183 (Redis) / #184 (Fly edge) revisited only once the server scales past one instance.
- Spectator / rating depth.
