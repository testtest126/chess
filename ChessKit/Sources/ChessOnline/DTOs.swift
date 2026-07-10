import Foundation

// Wire-level data transfer objects shared by the Vapor server and the iOS
// client. Deliberately independent of ChessKit: everything on the wire is
// strings and UUIDs so the protocol stays stable as engine types evolve.

// MARK: - Auth

/// POST /auth/register
public struct RegisterRequest: Codable, Sendable, Equatable {
    /// Optional preferred display name; the server generates one when omitted.
    public var displayName: String?

    public init(displayName: String? = nil) {
        self.displayName = displayName
    }
}

/// POST /auth/refresh
public struct RefreshRequest: Codable, Sendable, Equatable {
    public var refreshToken: String

    public init(refreshToken: String) {
        self.refreshToken = refreshToken
    }
}

/// Response for both /auth/register and /auth/refresh.
/// The refresh token rotates on every use; the client must store the new one.
public struct AuthResponse: Codable, Sendable, Equatable {
    public var userID: UUID
    public var displayName: String
    public var accessToken: String
    public var refreshToken: String
    /// Seconds until the access token expires.
    public var expiresIn: Int
    /// Elo rating for online play.
    public var rating: Int?

    public init(userID: UUID, displayName: String, accessToken: String, refreshToken: String, expiresIn: Int, rating: Int? = nil) {
        self.userID = userID
        self.displayName = displayName
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.rating = rating
    }
}

/// GET /me
public struct UserDTO: Codable, Sendable, Equatable {
    public var id: UUID
    public var displayName: String
    public var rating: Int?

    public init(id: UUID, displayName: String, rating: Int? = nil) {
        self.id = id
        self.displayName = displayName
        self.rating = rating
    }
}

// MARK: - Game history

/// GET /games and GET /games/:id
public struct GameRecordDTO: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var whiteID: UUID
    public var blackID: UUID
    public var whiteName: String
    public var blackName: String
    /// PGN result string: "1-0", "0-1", "1/2-1/2".
    public var result: String
    /// Raw Game.EndReason value, e.g. "checkmate", "resignation", "abandoned".
    public var endReason: String
    /// Space-separated UCI moves.
    public var uciMoves: String
    public var finishedAt: Date

    public init(
        id: UUID, whiteID: UUID, blackID: UUID,
        whiteName: String, blackName: String,
        result: String, endReason: String,
        uciMoves: String, finishedAt: Date
    ) {
        self.id = id
        self.whiteID = whiteID
        self.blackID = blackID
        self.whiteName = whiteName
        self.blackName = blackName
        self.result = result
        self.endReason = endReason
        self.uciMoves = uciMoves
        self.finishedAt = finishedAt
    }
}
