import Vapor

/// Adds baseline hardening headers to every response. This is a JSON API
/// with no HTML surface, so these mitigate second-order risk (a browser ever
/// rendering a response body, e.g. an error page or a misconfigured proxy)
/// rather than a direct attack this server itself is exposed to.
struct SecurityHeadersMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        // A JSON API is never a plausible framing target, but this costs
        // nothing and forecloses it outright.
        response.headers.replaceOrAdd(name: .init("X-Frame-Options"), value: "DENY")
        // Stops a browser from MIME-sniffing a response into something more
        // dangerous than the declared Content-Type (e.g. text/html).
        response.headers.replaceOrAdd(name: .init("X-Content-Type-Options"), value: "nosniff")
        // No page on this origin should ever leak the request URL (which can
        // carry a bearer-adjacent path segment, e.g. /players/:id) via the
        // Referer header on an outbound link.
        response.headers.replaceOrAdd(name: .init("Referrer-Policy"), value: "no-referrer")
        // Fly's edge terminates TLS and forwards over the same TLS
        // connection to the client, so this reaches browsers over HTTPS even
        // though Vapor itself only ever sees plain HTTP behind the proxy.
        // Harmless for the iOS client, which ignores it.
        response.headers.replaceOrAdd(
            name: .init("Strict-Transport-Security"),
            value: "max-age=31536000; includeSubDomains"
        )
        return response
    }
}
