import XCTest
@testable import ChessOnline

final class MessageCodingTests: XCTestCase {

    func testClientMessageRoundTrip() throws {
        let messages: [ClientMessage] = [.joinQueue, .leaveQueue, .move(uci: "e7e8q"), .resign]
        for message in messages {
            let decoded = try ClientMessage(jsonString: try message.jsonString())
            XCTAssertEqual(decoded, message)
        }
    }

    func testServerMessageRoundTrip() throws {
        let start = ServerMessage.GameStart(
            gameID: UUID(), yourColor: "black", opponentName: "Guest-1234", moves: ["e2e4", "c7c5"]
        )
        let messages: [ServerMessage] = [
            .queued,
            .gameStart(start),
            .movePlayed(uci: "g1f3"),
            .gameOver(result: "0-1", reason: "checkmate"),
            .opponentStatus(connected: false),
            .errorMessage("not your turn"),
        ]
        for message in messages {
            let decoded = try ServerMessage(jsonString: try message.jsonString())
            XCTAssertEqual(decoded, message)
        }
    }

    func testWireFormatUsesTypeDiscriminator() throws {
        let json = try ClientMessage.move(uci: "e2e4").jsonString()
        XCTAssertTrue(json.contains(#""type":"move""#))
        XCTAssertTrue(json.contains(#""uci":"e2e4""#))

        let decoded = try ClientMessage(jsonString: #"{"type":"join_queue"}"#)
        XCTAssertEqual(decoded, .joinQueue)
    }
}
