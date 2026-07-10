import Vapor
import ChessOnline

func routes(_ app: Application) throws {
    app.get("health") { _ in "ok" }

    try app.register(collection: AuthController())
    try app.register(collection: UsersController())
    try app.register(collection: GamesController())
    try app.register(collection: LeaderboardController())
    try app.register(collection: PlayersController())

    // Realtime play. The upgrade request must carry a valid bearer token;
    // anything else is closed immediately.
    //
    // Note: the token is checked in shouldUpgrade because JWT 5 verification is
    // async; running it before the 101 response also guarantees no client frame
    // can arrive before the handlers below are registered. Invalid tokens still
    // upgrade ([:]) so onUpgrade can close the socket with .policyViolation —
    // failing the future here would leave the client's upgrade request dangling
    // without a response. onUpgrade uses the synchronous overload deliberately —
    // it runs on the channel's event loop, which WebSocketKit requires for
    // registering onText/onClose handlers (they're NIOLoopBound).
    app.webSocket("play", shouldUpgrade: { req -> EventLoopFuture<HTTPHeaders?> in
        req.eventLoop.makeFutureWithTask {
            if let payload = try? await req.jwt.verify(as: UserPayload.self),
               let id = payload.userID {
                req.storage[AuthenticatedUserIDKey.self] = id
            }
            return [:]
        }
    }, onUpgrade: { req, ws in
        guard let userID = req.storage[AuthenticatedUserIDKey.self] else {
            _ = ws.close(code: .policyViolation)
            return
        }

        let coordinator = req.application.gameCoordinator
        let logger = req.logger

        ws.onText { ws, text in
            guard let message = try? ClientMessage(jsonString: text) else {
                logger.debug("unparseable client message from \(userID)")
                return
            }
            Task {
                await coordinator.handle(message, from: userID)
            }
        }

        ws.onClose.whenComplete { _ in
            Task {
                await coordinator.disconnect(userID: userID, socket: ws)
            }
        }

        Task {
            await coordinator.connect(userID: userID, socket: ws)
        }
    })
}

/// Carries the verified user ID from the upgrade check into the socket handler.
private struct AuthenticatedUserIDKey: StorageKey {
    typealias Value = UUID
}
