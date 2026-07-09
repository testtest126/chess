import Vapor
import Fluent
import ChessOnline

/// A finished online game. Names are denormalized so history listings don't
/// need joins, and moves are stored as space-separated UCI.
final class GameRecord: Model, Content, @unchecked Sendable {
    static let schema = "game_records"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "white_id")
    var whiteID: UUID

    @Field(key: "black_id")
    var blackID: UUID

    @Field(key: "white_name")
    var whiteName: String

    @Field(key: "black_name")
    var blackName: String

    @Field(key: "result")
    var result: String

    @Field(key: "end_reason")
    var endReason: String

    @Field(key: "uci_moves")
    var uciMoves: String

    @Timestamp(key: "finished_at", on: .create)
    var finishedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        whiteID: UUID, blackID: UUID,
        whiteName: String, blackName: String,
        result: String, endReason: String, uciMoves: String
    ) {
        self.id = id
        self.whiteID = whiteID
        self.blackID = blackID
        self.whiteName = whiteName
        self.blackName = blackName
        self.result = result
        self.endReason = endReason
        self.uciMoves = uciMoves
    }

    func dto() throws -> GameRecordDTO {
        GameRecordDTO(
            id: try requireID(),
            whiteID: whiteID,
            blackID: blackID,
            whiteName: whiteName,
            blackName: blackName,
            result: result,
            endReason: endReason,
            uciMoves: uciMoves,
            finishedAt: finishedAt ?? Date()
        )
    }
}
