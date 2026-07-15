@testable import App
import XCTVapor

final class SecurityHeadersMiddlewareTests: XCTestCase {
    var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    func testResponsesCarryBaselineSecurityHeaders() async throws {
        try await app.test(.GET, "health", afterResponse: { res async in
            XCTAssertEqual(res.headers.first(name: "X-Frame-Options"), "DENY")
            XCTAssertEqual(res.headers.first(name: "X-Content-Type-Options"), "nosniff")
            XCTAssertEqual(res.headers.first(name: "Referrer-Policy"), "no-referrer")
            XCTAssertEqual(res.headers.first(name: "Strict-Transport-Security"), "max-age=31536000; includeSubDomains")
        })
    }

    func testHeadersAreAlsoPresentOnErrorResponses() async throws {
        // The middleware wraps every response, including ones the default
        // error handler generates further down the chain (a 404 here).
        try await app.test(.GET, "no-such-route", afterResponse: { res async in
            XCTAssertEqual(res.headers.first(name: "X-Content-Type-Options"), "nosniff")
        })
    }
}
