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

/// POST /auth/apple — sign in (or link the current guest account) with an
/// Apple identity token from AuthenticationServices.
public struct AppleSignInRequest: Codable, Sendable, Equatable {
    /// The JWT from `ASAuthorizationAppleIDCredential.identityToken`.
    public var identityToken: String
    /// Preferred display name for a newly created account (Apple only
    /// provides the name on first authorization).
    public var displayName: String?

    public init(identityToken: String, displayName: String? = nil) {
        self.identityToken = identityToken
        self.displayName = displayName
    }
}

/// Response for /auth/register, /auth/refresh, and /auth/apple.
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
    /// Whether this account is recoverable via Sign in with Apple.
    public var appleLinked: Bool?

    public init(
        userID: UUID, displayName: String, accessToken: String, refreshToken: String,
        expiresIn: Int, rating: Int? = nil, appleLinked: Bool? = nil
    ) {
        self.userID = userID
        self.displayName = displayName
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.rating = rating
        self.appleLinked = appleLinked
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

// MARK: - Leaderboard

/// GET /leaderboard — top players by rating, best first.
public struct LeaderboardEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var displayName: String
    public var rating: Int
    /// Finished online games.
    public var games: Int

    public init(id: UUID, displayName: String, rating: Int, games: Int) {
        self.id = id
        self.displayName = displayName
        self.rating = rating
        self.games = games
    }
}

// MARK: - Player profiles

/// GET /players/:id — a player's public profile: rating and lifetime record.
/// Visible to any signed-in player (like the leaderboard); game *contents*
/// remain participants-only.
public struct PlayerProfileDTO: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var displayName: String
    public var rating: Int
    public var wins: Int
    public var draws: Int
    public var losses: Int
    public var memberSince: Date

    /// Finished online games.
    public var games: Int { wins + draws + losses }

    public init(
        id: UUID, displayName: String, rating: Int,
        wins: Int, draws: Int, losses: Int, memberSince: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.rating = rating
        self.wins = wins
        self.draws = draws
        self.losses = losses
        self.memberSince = memberSince
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
    /// The control the game was played at (nil for records that predate
    /// selectable time controls).
    public var timeControl: TimeControl?

    public init(
        id: UUID, whiteID: UUID, blackID: UUID,
        whiteName: String, blackName: String,
        result: String, endReason: String,
        uciMoves: String, finishedAt: Date,
        timeControl: TimeControl? = nil
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
        self.timeControl = timeControl
    }
}
