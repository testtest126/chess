import Foundation
import ChessOnline

/// One WebSocket connection to the server's /play endpoint. Messages arrive
/// in order on `messages`; the stream finishes when the socket dies.
final class OnlineGameClient: Sendable {
    let messages: AsyncStream<ServerMessage>

    private let task: URLSessionWebSocketTask
    private let continuation: AsyncStream<ServerMessage>.Continuation

    init(url: URL, accessToken: String) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        self.task = URLSession.shared.webSocketTask(with: request)
        (self.messages, self.continuation) = AsyncStream.makeStream(of: ServerMessage.self)
    }

    /// Opens the socket and pumps incoming messages into `messages`.
    func connect() {
        task.resume()
        Task { [task, continuation] in
            while true {
                do {
                    let raw = try await task.receive()
                    let text: String
                    switch raw {
                    case .string(let string):
                        text = string
                    case .data(let data):
                        text = String(decoding: data, as: UTF8.self)
                    @unknown default:
                        continue
                    }
                    if let message = try? ServerMessage(jsonString: text) {
                        continuation.yield(message)
                    }
                } catch {
                    break
                }
            }
            continuation.finish()
        }
    }

    func send(_ message: ClientMessage) async throws {
        try await task.send(.string(message.jsonString()))
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        continuation.finish()
    }
}
