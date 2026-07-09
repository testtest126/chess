import Foundation

// JSON messages exchanged over the /play WebSocket. Both enums encode with a
// "type" discriminator field so the wire format is self-describing:
//   {"type":"move","uci":"e2e4"}
//   {"type":"game_start","gameID":"…","yourColor":"white","opponentName":"…","moves":[]}

// MARK: - Client → Server

public enum ClientMessage: Sendable, Equatable {
    /// Enter the matchmaking queue.
    case joinQueue
    /// Leave the queue before a match is found.
    case leaveQueue
    /// Play a move in the caller's active game.
    case move(uci: String)
    /// Resign the caller's active game.
    case resign
}

extension ClientMessage: Codable {
    private enum Kind: String, Codable {
        case joinQueue = "join_queue"
        case leaveQueue = "leave_queue"
        case move
        case resign
    }

    private enum CodingKeys: String, CodingKey {
        case type, uci
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .joinQueue: self = .joinQueue
        case .leaveQueue: self = .leaveQueue
        case .move: self = .move(uci: try container.decode(String.self, forKey: .uci))
        case .resign: self = .resign
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .joinQueue:
            try container.encode(Kind.joinQueue, forKey: .type)
        case .leaveQueue:
            try container.encode(Kind.leaveQueue, forKey: .type)
        case .move(let uci):
            try container.encode(Kind.move, forKey: .type)
            try container.encode(uci, forKey: .uci)
        case .resign:
            try container.encode(Kind.resign, forKey: .type)
        }
    }
}

// MARK: - Server → Client

public enum ServerMessage: Sendable, Equatable {
    /// Acknowledges queue entry.
    case queued
    /// A match started, or the client reconnected to its game in progress.
    /// `moves` replays the game so far (empty for a fresh match).
    case gameStart(GameStart)
    /// A legal move was played by either side (including echo of your own).
    case movePlayed(uci: String)
    /// The game ended. `result` is "1-0"/"0-1"/"1/2-1/2"; `reason` is the raw
    /// Game.EndReason ("checkmate", "resignation", "abandoned", …).
    case gameOver(result: String, reason: String)
    /// The opponent's connection state changed. Disconnected opponents forfeit
    /// after a grace period unless they reconnect.
    case opponentStatus(connected: Bool)
    /// A request could not be honored (illegal move, not your turn, …).
    case errorMessage(String)

    public struct GameStart: Codable, Sendable, Equatable {
        public var gameID: UUID
        /// "white" or "black".
        public var yourColor: String
        public var opponentName: String
        /// UCI moves already played (non-empty only on reconnect).
        public var moves: [String]

        public init(gameID: UUID, yourColor: String, opponentName: String, moves: [String]) {
            self.gameID = gameID
            self.yourColor = yourColor
            self.opponentName = opponentName
            self.moves = moves
        }
    }
}

extension ServerMessage: Codable {
    private enum Kind: String, Codable {
        case queued
        case gameStart = "game_start"
        case movePlayed = "move_played"
        case gameOver = "game_over"
        case opponentStatus = "opponent_status"
        case error
    }

    private enum CodingKeys: String, CodingKey {
        case type, uci, result, reason, connected, message
        case gameID, yourColor, opponentName, moves
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .queued:
            self = .queued
        case .gameStart:
            self = .gameStart(GameStart(
                gameID: try container.decode(UUID.self, forKey: .gameID),
                yourColor: try container.decode(String.self, forKey: .yourColor),
                opponentName: try container.decode(String.self, forKey: .opponentName),
                moves: try container.decode([String].self, forKey: .moves)
            ))
        case .movePlayed:
            self = .movePlayed(uci: try container.decode(String.self, forKey: .uci))
        case .gameOver:
            self = .gameOver(
                result: try container.decode(String.self, forKey: .result),
                reason: try container.decode(String.self, forKey: .reason)
            )
        case .opponentStatus:
            self = .opponentStatus(connected: try container.decode(Bool.self, forKey: .connected))
        case .error:
            self = .errorMessage(try container.decode(String.self, forKey: .message))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .queued:
            try container.encode(Kind.queued, forKey: .type)
        case .gameStart(let start):
            try container.encode(Kind.gameStart, forKey: .type)
            try container.encode(start.gameID, forKey: .gameID)
            try container.encode(start.yourColor, forKey: .yourColor)
            try container.encode(start.opponentName, forKey: .opponentName)
            try container.encode(start.moves, forKey: .moves)
        case .movePlayed(let uci):
            try container.encode(Kind.movePlayed, forKey: .type)
            try container.encode(uci, forKey: .uci)
        case .gameOver(let result, let reason):
            try container.encode(Kind.gameOver, forKey: .type)
            try container.encode(result, forKey: .result)
            try container.encode(reason, forKey: .reason)
        case .opponentStatus(let connected):
            try container.encode(Kind.opponentStatus, forKey: .type)
            try container.encode(connected, forKey: .connected)
        case .errorMessage(let message):
            try container.encode(Kind.error, forKey: .type)
            try container.encode(message, forKey: .message)
        }
    }
}

// MARK: - Framing helpers

public extension ClientMessage {
    func jsonString() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    init(jsonString: String) throws {
        self = try JSONDecoder().decode(ClientMessage.self, from: Data(jsonString.utf8))
    }
}

public extension ServerMessage {
    func jsonString() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    init(jsonString: String) throws {
        self = try JSONDecoder().decode(ServerMessage.self, from: Data(jsonString.utf8))
    }
}
