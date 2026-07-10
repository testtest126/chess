import Foundation

// JSON messages exchanged over the /play WebSocket. Both enums encode with a
// "type" discriminator field so the wire format is self-describing:
//   {"type":"move","uci":"e2e4"}
//   {"type":"game_start","gameID":"…","yourColor":"white","opponentName":"…","moves":[]}

// MARK: - Shared payloads

/// A named time control a player can queue for. The raw value is the wire
/// string carried by join_queue and echoed back in game_start.
public enum TimeControl: String, Codable, Sendable, CaseIterable, Equatable {
    case bullet
    case blitz
    case rapid

    /// Seconds each side starts with.
    public var initialSeconds: Double {
        switch self {
        case .bullet: return 60
        case .blitz: return 300
        case .rapid: return 600
        }
    }

    /// Seconds added to a side's clock after each of its moves.
    public var incrementSeconds: Double {
        switch self {
        case .bullet: return 0
        case .blitz: return 3
        case .rapid: return 5
        }
    }

    /// Conventional "minutes+increment" notation: "1+0", "5+3", "10+5".
    public var shortLabel: String {
        "\(Int(initialSeconds) / 60)+\(Int(incrementSeconds))"
    }

    /// Peers that predate time controls always played 5+3, so blitz is
    /// assumed whenever the field is absent from a message.
    public static let `default`: TimeControl = .blitz
}

/// Remaining thinking time for both sides, in seconds, as of the moment the
/// enclosing message was sent. The receiver ticks the active side locally.
public struct ClockState: Codable, Sendable, Equatable {
    public var whiteSeconds: Double
    public var blackSeconds: Double

    public init(whiteSeconds: Double, blackSeconds: Double) {
        self.whiteSeconds = whiteSeconds
        self.blackSeconds = blackSeconds
    }
}

// MARK: - Client → Server

public enum ClientMessage: Sendable, Equatable {
    /// Enter the matchmaking queue for the given time control. Only players
    /// waiting for the same control are paired.
    case joinQueue(timeControl: TimeControl)
    /// Leave the queue before a match is found.
    case leaveQueue
    /// Play a move in the caller's active game.
    case move(uci: String)
    /// Resign the caller's active game.
    case resign
    /// Offer the opponent a draw (valid until they move).
    case offerDraw
    /// Accept the opponent's pending draw offer.
    case acceptDraw
    /// Decline the opponent's pending draw offer.
    case declineDraw
    /// After a game ends: ask to play the same opponent again (colors
    /// swapped). The rematch starts when both players have asked.
    case requestRematch
}

extension ClientMessage: Codable {
    private enum Kind: String, Codable {
        case joinQueue = "join_queue"
        case leaveQueue = "leave_queue"
        case move
        case resign
        case offerDraw = "offer_draw"
        case acceptDraw = "accept_draw"
        case declineDraw = "decline_draw"
        case requestRematch = "request_rematch"
    }

    private enum CodingKeys: String, CodingKey {
        case type, uci, timeControl
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .joinQueue:
            // Absent on peers that predate selectable controls: assume 5+3.
            self = .joinQueue(timeControl:
                try container.decodeIfPresent(TimeControl.self, forKey: .timeControl) ?? .default
            )
        case .leaveQueue: self = .leaveQueue
        case .move: self = .move(uci: try container.decode(String.self, forKey: .uci))
        case .resign: self = .resign
        case .offerDraw: self = .offerDraw
        case .acceptDraw: self = .acceptDraw
        case .declineDraw: self = .declineDraw
        case .requestRematch: self = .requestRematch
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .joinQueue(let timeControl):
            try container.encode(Kind.joinQueue, forKey: .type)
            try container.encode(timeControl, forKey: .timeControl)
        case .leaveQueue:
            try container.encode(Kind.leaveQueue, forKey: .type)
        case .move(let uci):
            try container.encode(Kind.move, forKey: .type)
            try container.encode(uci, forKey: .uci)
        case .resign:
            try container.encode(Kind.resign, forKey: .type)
        case .offerDraw:
            try container.encode(Kind.offerDraw, forKey: .type)
        case .acceptDraw:
            try container.encode(Kind.acceptDraw, forKey: .type)
        case .declineDraw:
            try container.encode(Kind.declineDraw, forKey: .type)
        case .requestRematch:
            try container.encode(Kind.requestRematch, forKey: .type)
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
    /// `clock` reflects both remaining times right after the move.
    case movePlayed(uci: String, clock: ClockState?)
    /// The game ended. `result` is "1-0"/"0-1"/"1/2-1/2"; `reason` is the raw
    /// Game.EndReason ("checkmate", "resignation", "timeout", "abandoned", …).
    /// Rating deltas are present for rated games.
    case gameOver(GameOver)
    /// The opponent offered a draw (valid until either side moves).
    case drawOffered
    /// The opponent declined your draw offer.
    case drawDeclined
    /// The opponent asked for a rematch of the game that just ended.
    case rematchOffered
    /// A rematch can no longer happen (the opponent left or queued anew).
    case rematchUnavailable
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
        public var opponentRating: Int?
        /// UCI moves already played (non-empty only on reconnect).
        public var moves: [String]
        public var clock: ClockState?
        /// The control this game is played at (nil from older servers).
        public var timeControl: TimeControl?

        public init(
            gameID: UUID,
            yourColor: String,
            opponentName: String,
            opponentRating: Int? = nil,
            moves: [String],
            clock: ClockState? = nil,
            timeControl: TimeControl? = nil
        ) {
            self.gameID = gameID
            self.yourColor = yourColor
            self.opponentName = opponentName
            self.opponentRating = opponentRating
            self.moves = moves
            self.clock = clock
            self.timeControl = timeControl
        }
    }

    public struct GameOver: Codable, Sendable, Equatable {
        public var result: String
        public var reason: String
        public var ratingDeltaWhite: Int?
        public var ratingDeltaBlack: Int?

        public init(result: String, reason: String, ratingDeltaWhite: Int? = nil, ratingDeltaBlack: Int? = nil) {
            self.result = result
            self.reason = reason
            self.ratingDeltaWhite = ratingDeltaWhite
            self.ratingDeltaBlack = ratingDeltaBlack
        }
    }
}

extension ServerMessage: Codable {
    private enum Kind: String, Codable {
        case queued
        case gameStart = "game_start"
        case movePlayed = "move_played"
        case gameOver = "game_over"
        case drawOffered = "draw_offered"
        case drawDeclined = "draw_declined"
        case rematchOffered = "rematch_offered"
        case rematchUnavailable = "rematch_unavailable"
        case opponentStatus = "opponent_status"
        case error
    }

    private enum CodingKeys: String, CodingKey {
        case type, uci, result, reason, connected, message
        case gameID, yourColor, opponentName, opponentRating, moves, clock, timeControl
        case ratingDeltaWhite, ratingDeltaBlack
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
                opponentRating: try container.decodeIfPresent(Int.self, forKey: .opponentRating),
                moves: try container.decode([String].self, forKey: .moves),
                clock: try container.decodeIfPresent(ClockState.self, forKey: .clock),
                timeControl: try container.decodeIfPresent(TimeControl.self, forKey: .timeControl)
            ))
        case .movePlayed:
            self = .movePlayed(
                uci: try container.decode(String.self, forKey: .uci),
                clock: try container.decodeIfPresent(ClockState.self, forKey: .clock)
            )
        case .gameOver:
            self = .gameOver(GameOver(
                result: try container.decode(String.self, forKey: .result),
                reason: try container.decode(String.self, forKey: .reason),
                ratingDeltaWhite: try container.decodeIfPresent(Int.self, forKey: .ratingDeltaWhite),
                ratingDeltaBlack: try container.decodeIfPresent(Int.self, forKey: .ratingDeltaBlack)
            ))
        case .drawOffered:
            self = .drawOffered
        case .drawDeclined:
            self = .drawDeclined
        case .rematchOffered:
            self = .rematchOffered
        case .rematchUnavailable:
            self = .rematchUnavailable
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
            try container.encodeIfPresent(start.opponentRating, forKey: .opponentRating)
            try container.encode(start.moves, forKey: .moves)
            try container.encodeIfPresent(start.clock, forKey: .clock)
            try container.encodeIfPresent(start.timeControl, forKey: .timeControl)
        case .movePlayed(let uci, let clock):
            try container.encode(Kind.movePlayed, forKey: .type)
            try container.encode(uci, forKey: .uci)
            try container.encodeIfPresent(clock, forKey: .clock)
        case .gameOver(let over):
            try container.encode(Kind.gameOver, forKey: .type)
            try container.encode(over.result, forKey: .result)
            try container.encode(over.reason, forKey: .reason)
            try container.encodeIfPresent(over.ratingDeltaWhite, forKey: .ratingDeltaWhite)
            try container.encodeIfPresent(over.ratingDeltaBlack, forKey: .ratingDeltaBlack)
        case .drawOffered:
            try container.encode(Kind.drawOffered, forKey: .type)
        case .drawDeclined:
            try container.encode(Kind.drawDeclined, forKey: .type)
        case .rematchOffered:
            try container.encode(Kind.rematchOffered, forKey: .type)
        case .rematchUnavailable:
            try container.encode(Kind.rematchUnavailable, forKey: .type)
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
