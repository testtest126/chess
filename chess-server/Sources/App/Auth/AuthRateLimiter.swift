import Vapor

/// Fixed-window request counter keyed by client, used to throttle the
/// unauthenticated auth endpoints. A window opens on a key's first request
/// and admits `limit` requests until `window` seconds have passed; later
/// requests are refused with the seconds remaining until the window resets.
actor FixedWindowRateLimiter {
    enum Verdict: Equatable {
        case allowed
        case limited(retryAfter: TimeInterval)
    }

    private struct Window {
        var start: Date
        var count: Int
    }

    private let limit: Int
    private let window: TimeInterval
    private var windows: [String: Window] = [:]

    /// Entry count above which expired windows are swept out, so an attacker
    /// rotating source addresses can't grow the dictionary without bound.
    private let pruneThreshold = 4096

    init(limit: Int, window: TimeInterval = 60) {
        self.limit = max(1, limit)
        self.window = window
    }

    func check(_ key: String, now: Date = Date()) -> Verdict {
        if windows.count > pruneThreshold {
            windows = windows.filter { now.timeIntervalSince($0.value.start) < window }
        }

        if var current = windows[key], now.timeIntervalSince(current.start) < window {
            guard current.count < limit else {
                return .limited(retryAfter: window - now.timeIntervalSince(current.start))
            }
            current.count += 1
            windows[key] = current
            return .allowed
        }

        windows[key] = Window(start: now, count: 1)
        return .allowed
    }
}

/// Applies the application's rate limiter to a route group, keyed by client
/// IP. Refusals are 429 with a Retry-After header.
struct AuthRateLimitMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let verdict = await request.application.authRateLimiter.check(clientKey(for: request))
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
        typealias Value = FixedWindowRateLimiter
    }

    /// Shared limiter for the auth endpoints. Configured in `configure(_:)`;
    /// tests install a tighter one to exercise the 429 path.
    var authRateLimiter: FixedWindowRateLimiter {
        get { storage[AuthRateLimiterKey.self] ?? FixedWindowRateLimiter(limit: .max) }
        set { storage[AuthRateLimiterKey.self] = newValue }
    }
}
