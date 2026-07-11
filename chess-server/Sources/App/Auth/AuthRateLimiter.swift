import Vapor
import Fluent
import SQLKit

/// Sliding-window request counter shared through the application database,
/// used to throttle the unauthenticated auth endpoints. Counters live in the
/// `auth_rate_windows` table rather than process memory, so every server
/// instance draws from the same budget and restarts don't reset windows (#79).
///
/// The window slides: requests land in fixed buckets of `window` seconds, and
/// a verdict weighs the current bucket plus the previous one decayed linearly
/// by how far the current bucket has progressed. A burst straddling a bucket
/// boundary therefore can't get 2× the limit the way plain fixed windows
/// allow. Refused requests count too, but only up to one past the limit —
/// hammering can't wedge the counter, so once the traffic stops the key is
/// admitted again after rollover, the same recovery the fixed window gave.
actor SlidingWindowRateLimiter {
    enum Verdict: Equatable {
        case allowed
        case limited(retryAfter: TimeInterval)
    }

    private let limit: Int
    private let window: TimeInterval
    private var lastSweep: Date = .distantPast

    init(limit: Int, window: TimeInterval = 60) {
        self.limit = max(1, limit)
        self.window = max(1, window)
    }

    private struct CountRow: Decodable {
        var count: Int
    }

    func check(_ key: String, on database: any Database, now: Date = Date()) async throws -> Verdict {
        guard let sql = database as? any SQLDatabase else {
            // Both supported drivers (Postgres, SQLite) are SQL databases;
            // reaching this means a misconfigured fixture, not a client at
            // fault — and a limiter that can't count must not admit.
            throw Abort(.internalServerError, reason: "rate limiter requires a SQL database")
        }

        // Real keys are IP addresses (≤45 chars); a hostile proxy-supplied
        // header must not be able to blow past index row-size limits and
        // turn the counter upsert into an error path.
        let key = String(key.prefix(64))

        let bucket = Int(now.timeIntervalSince1970 / window)
        let fraction = (now.timeIntervalSince1970 - Double(bucket) * window) / window

        // One atomic statement counts this request and reads the result, so
        // concurrent requests across instances can never both see the last
        // free slot. The CASE saturates the count one past the limit (see
        // the type comment).
        let current = try await sql.raw("""
        INSERT INTO "auth_rate_windows" ("key", "bucket", "count")
        VALUES (\(bind: key), \(bind: bucket), 1)
        ON CONFLICT ("key", "bucket")
        DO UPDATE SET "count" = CASE
            WHEN "auth_rate_windows"."count" > \(bind: limit) THEN "auth_rate_windows"."count"
            ELSE "auth_rate_windows"."count" + 1
        END
        RETURNING "count"
        """).first(decoding: CountRow.self)?.count ?? 1

        let previous = try await sql.raw("""
        SELECT "count" FROM "auth_rate_windows"
        WHERE "key" = \(bind: key) AND "bucket" = \(bind: bucket - 1)
        """).first(decoding: CountRow.self)?.count ?? 0

        let weighted = Double(previous) * (1 - fraction) + Double(current)
        let verdict: Verdict = weighted <= Double(limit)
            ? .allowed
            : .limited(retryAfter: retryAfter(previous: previous, current: current, fraction: fraction))

        // Housekeeping runs after the verdict is decided and never fails the
        // request.
        await sweepIfDue(sql, currentBucket: bucket, now: now)
        return verdict
    }

    /// Seconds until a retry would be admitted, assuming the client goes
    /// quiet meanwhile (further requests push this out — they count too).
    private func retryAfter(previous: Int, current: Int, fraction: Double) -> TimeInterval {
        let limit = Double(self.limit)

        // Still within the current bucket, the previous bucket's weight
        // decays: a retry at fraction g adds one to `current` and is admitted
        // once previous × (1 − g) + current + 1 ≤ limit.
        if previous > 0 {
            let g = 1 - (limit - Double(current) - 1) / Double(previous)
            if g <= 1 {
                return max(1, (g - fraction) * window)
            }
        }

        // Otherwise wait for rollover, when this bucket becomes the previous
        // one and decays in turn: current × (1 − g) + 1 ≤ limit.
        let g = max(0, 1 - (limit - 1) / Double(current))
        return max(1, (1 - fraction + g) * window)
    }

    /// Buckets outside current±1 no longer influence any verdict: previous
    /// feeds the decay, current+1 tolerates a clock-ahead peer instance, and
    /// everything else — including rows stranded by an
    /// AUTH_RATE_LIMIT_WINDOW change, which renumbers buckets — is
    /// reclaimed. Sweeping at most once per window keeps the table at a few
    /// rows per recently active key, so an attacker rotating source
    /// addresses can't grow it without bound. Errors are logged, not
    /// thrown: housekeeping must never fail an already-decided request.
    private func sweepIfDue(_ sql: any SQLDatabase, currentBucket: Int, now: Date) async {
        guard now.timeIntervalSince(lastSweep) >= window else { return }
        lastSweep = now
        do {
            try await sql.raw("""
            DELETE FROM "auth_rate_windows"
            WHERE "bucket" < \(bind: currentBucket - 1) OR "bucket" > \(bind: currentBucket + 1)
            """).run()
        } catch {
            sql.logger.warning("auth rate limiter sweep failed: \(String(reflecting: error))")
        }
    }
}

/// Applies the application's rate limiter to a route group, keyed by client
/// IP. Refusals are 429 with a Retry-After header.
struct AuthRateLimitMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let verdict = try await request.application.authRateLimiter
            .check(clientKey(for: request), on: request.db)
        if case .limited(let retryAfter) = verdict {
            let seconds = max(1, Int(retryAfter.rounded(.up)))
            throw Abort(.tooManyRequests,
                        headers: ["Retry-After": "\(seconds)"],
                        reason: "too many requests; retry in \(seconds)s")
        }
        return try await next.respond(to: request)
    }

    /// The socket's peer address, unless TRUST_PROXY_HEADERS is set — then
    /// what the trusted proxy says. Fly-Client-IP wins when present: Fly's
    /// proxy overwrites it with the real client address, whereas Fly's
    /// X-Forwarded-For puts the *app's own IP* rightmost, which would fold
    /// every client into a single bucket. The last-XFF fallback stays for
    /// conventional proxies (nginx et al.) that append the peer they saw.
    /// Earlier XFF entries are client-controlled and must never be trusted,
    /// and without a trusted proxy every header is forgeable, hence the
    /// opt-in. A request with no resolvable address shares one bucket rather
    /// than bypassing the limit.
    private func clientKey(for request: Request) -> String {
        if request.application.environment.isTrustingProxyHeaders {
            if let flyClient = request.headers.first(name: "Fly-Client-IP"),
               !flyClient.isEmpty {
                return flyClient
            }
            if let forwarded = request.headers[.xForwardedFor].first {
                let entries = forwarded.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if let closest = entries.last, !closest.isEmpty {
                    return closest
                }
            }
        }
        return request.remoteAddress?.ipAddress ?? "unknown"
    }
}

extension Environment {
    var isTrustingProxyHeaders: Bool {
        Environment.get("TRUST_PROXY_HEADERS") != nil
    }
}

extension Application {
    private struct AuthRateLimiterKey: StorageKey {
        typealias Value = SlidingWindowRateLimiter
    }

    /// Shared limiter for the auth endpoints. Configured in `configure(_:)`;
    /// tests install a tighter one to exercise the 429 path.
    var authRateLimiter: SlidingWindowRateLimiter {
        get { storage[AuthRateLimiterKey.self] ?? SlidingWindowRateLimiter(limit: .max) }
        set { storage[AuthRateLimiterKey.self] = newValue }
    }
}
