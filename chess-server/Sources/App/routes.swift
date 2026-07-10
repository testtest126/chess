import Vapor
import ChessOnline

func routes(_ app: Application) throws {
    app.get("health") { _ in "ok" }

    try app.register(collection: AuthController())
    try app.register(collection: UsersController())
    try app.register(collection: GamesController())
    try app.register(collection: LeaderboardController())

    // Realtime play. The upgrade request must carry a valid bearer token;
    // anything else is closed immediately.
    //
    // Note: this uses the synchronous onUpgrade overload deliberately — it runs
    // on the channel's event loop, which WebSocketKit requires for registering
    // onText/onClose handlers (they're NIOLoopBound). JWT verification is pure
    // CPU work, so nothing here blocks the loop.
    app.webSocket("play") { req, ws in
        let userID: UUID
        do {
            let payload = try req.jwt.verify(as: UserPayload.self)
            guard let id = payload.userID else {
                throw Abort(.unauthorized, reason: "malformed subject claim")
            }
            userID = id
        } catch {
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
    }
}
