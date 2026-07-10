import XCTest
@testable import ChessOnline

final class MessageCodingTests: XCTestCase {

    func testClientMessageRoundTrip() throws {
        let messages: [ClientMessage] = [
            .joinQueue(timeControl: .bullet), .joinQueue(timeControl: .blitz),
            .joinQueue(timeControl: .rapid),
            .leaveQueue, .move(uci: "e7e8q"), .resign,
            .offerDraw, .acceptDraw, .declineDraw, .requestRematch,
        ]
        for message in messages {
            let decoded = try ClientMessage(jsonString: try message.jsonString())
            XCTAssertEqual(decoded, message)
        }
    }

    func testServerMessageRoundTrip() throws {
        let start = ServerMessage.GameStart(
            gameID: UUID(), yourColor: "black", opponentName: "Guest-1234",
            opponentRating: 1234, moves: ["e2e4", "c7c5"],
            clock: ClockState(whiteSeconds: 300, blackSeconds: 287.5),
            timeControl: .rapid
        )
        let messages: [ServerMessage] = [
            .queued,
            .gameStart(start),
            .movePlayed(uci: "g1f3", clock: ClockState(whiteSeconds: 100, blackSeconds: 50)),
            .movePlayed(uci: "g1f3", clock: nil),
            .gameOver(.init(result: "0-1", reason: "checkmate", ratingDeltaWhite: -16, ratingDeltaBlack: 16)),
            .gameOver(.init(result: "1/2-1/2", reason: "drawAgreement")),
            .drawOffered,
            .drawDeclined,
            .rematchOffered,
            .rematchUnavailable,
            .opponentStatus(connected: false),
            .errorMessage("not your turn"),
        ]
        for message in messages {
            let decoded = try ServerMessage(jsonString: try message.jsonString())
            XCTAssertEqual(decoded, message)
        }
    }

    func testOptionalFieldsDecodeWhenAbsent() throws {
        // Older peers may omit clock/rating/control fields entirely.
        let start = try ServerMessage(jsonString:
            #"{"type":"game_start","gameID":"00000000-0000-0000-0000-000000000000","yourColor":"white","opponentName":"X","moves":[]}"#
        )
        guard case .gameStart(let payload) = start else { return XCTFail() }
        XCTAssertNil(payload.clock)
        XCTAssertNil(payload.opponentRating)
        XCTAssertNil(payload.timeControl)

        let move = try ServerMessage(jsonString: #"{"type":"move_played","uci":"e2e4"}"#)
        XCTAssertEqual(move, .movePlayed(uci: "e2e4", clock: nil))
    }

    func testWireFormatUsesTypeDiscriminator() throws {
        let json = try ClientMessage.move(uci: "e2e4").jsonString()
        XCTAssertTrue(json.contains(#""type":"move""#))
        XCTAssertTrue(json.contains(#""uci":"e2e4""#))

        // A join_queue without a control (pre-time-controls client) is 5+3.
        let decoded = try ClientMessage(jsonString: #"{"type":"join_queue"}"#)
        XCTAssertEqual(decoded, .joinQueue(timeControl: .blitz))
    }

    func testJoinQueueCarriesTimeControl() throws {
        let json = try ClientMessage.joinQueue(timeControl: .bullet).jsonString()
        XCTAssertTrue(json.contains(#""type":"join_queue""#))
        XCTAssertTrue(json.contains(#""timeControl":"bullet""#))

        let decoded = try ClientMessage(jsonString: #"{"type":"join_queue","timeControl":"rapid"}"#)
        XCTAssertEqual(decoded, .joinQueue(timeControl: .rapid))
    }

    func testTimeControlParameters() {
        XCTAssertEqual(TimeControl.bullet.initialSeconds, 60)
        XCTAssertEqual(TimeControl.bullet.incrementSeconds, 0)
        XCTAssertEqual(TimeControl.blitz.initialSeconds, 300)
        XCTAssertEqual(TimeControl.blitz.incrementSeconds, 3)
        XCTAssertEqual(TimeControl.rapid.initialSeconds, 600)
        XCTAssertEqual(TimeControl.rapid.incrementSeconds, 5)
        XCTAssertEqual(TimeControl.bullet.shortLabel, "1+0")
        XCTAssertEqual(TimeControl.blitz.shortLabel, "5+3")
        XCTAssertEqual(TimeControl.rapid.shortLabel, "10+5")
        // The pre-time-controls fixed control stays the default.
        XCTAssertEqual(TimeControl.default, .blitz)
    }
}
