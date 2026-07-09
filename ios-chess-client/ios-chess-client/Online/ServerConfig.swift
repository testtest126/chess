import Foundation

/// Where the backend lives. Debug builds default to a locally running server
/// (`swift run App serve` in chess-server); release builds must point at the
/// deployed HTTPS endpoint. Both can be overridden with the "server_base_url"
/// user default, e.g. for testing a device against a LAN machine.
enum ServerConfig {
    static var httpBase: URL {
        if let override = UserDefaults.standard.string(forKey: "server_base_url"),
           let url = URL(string: override) {
            return url
        }
        #if DEBUG
        return URL(string: "http://127.0.0.1:8080")!
        #else
        return URL(string: "https://chess.example.com")! // TODO: deployed server
        #endif
    }

    /// The /play WebSocket endpoint, derived from `httpBase` (http → ws).
    static var playSocketURL: URL {
        var components = URLComponents(url: httpBase, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/play"
        return components.url!
    }
}
