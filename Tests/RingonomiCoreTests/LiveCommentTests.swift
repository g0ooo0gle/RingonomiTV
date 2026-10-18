import Foundation
import XCTest
@testable import RingonomiCore

final class LiveCommentTests: XCTestCase {
    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }

    func testWebSocketInfoAllowsNullEndpointsAndRejectsMissingRequiredFields() throws {
        let decoder = JSONDecoder()
        let info = try decoder.decode(
            JikkyoWebSocketInfo.self,
            from: data(#"{"watch_session_url":null,"comment_session_url":null,"is_nxjikkyo_exclusive":true}"#)
        )
        XCTAssertNil(info.watchSessionURL)
        XCTAssertNil(info.commentSessionURL)
        XCTAssertTrue(info.isNXJikkyoExclusive)

        XCTAssertThrowsError(try decoder.decode(
            JikkyoWebSocketInfo.self,
            from: data(#"{"watch_session_url":null,"is_nxjikkyo_exclusive":true}"#)
        )) { error in
            XCTAssertEqual(error as? LiveCommentError, .invalidMessage)
        }

        XCTAssertThrowsError(try decoder.decode(
            JikkyoWebSocketInfo.self,
            from: data(#"{"watch_session_url":null,"comment_session_url":null,"nicolive_watch_session_url":1,"is_nxjikkyo_exclusive":true}"#)
        )) { error in
            XCTAssertEqual(error as? LiveCommentError, .invalidMessage)
        }
    }

    func testWebSocketURLValidationRejectsHTTPUserInfoFragmentsAndOversizedValues() throws {
        let decoder = JSONDecoder()
        let cases = [
            #"{"watch_session_url":"https://example.invalid/watch","comment_session_url":null,"is_nxjikkyo_exclusive":false}"#,
            #"{"watch_session_url":"wss://user:pass@example.invalid/watch","comment_session_url":null,"is_nxjikkyo_exclusive":false}"#,
            #"{"watch_session_url":"wss://example.invalid/watch#fragment","comment_session_url":null,"is_nxjikkyo_exclusive":false}"#
        ]
        for value in cases {
            XCTAssertThrowsError(try decoder.decode(JikkyoWebSocketInfo.self, from: data(value))) { error in
                XCTAssertEqual(error as? LiveCommentError, .invalidWebSocketURL)
            }
        }

        let oversized = String(repeating: "a", count: LiveCommentProtocol.maximumURLBytes)
        let oversizedJSON = #"{"watch_session_url":"wss://example.invalid/"# + oversized + #"","comment_session_url":null,"is_nxjikkyo_exclusive":false}"#
        XCTAssertThrowsError(try decoder.decode(JikkyoWebSocketInfo.self, from: data(oversizedJSON))) { error in
            XCTAssertEqual(error as? LiveCommentError, .invalidWebSocketURL)
        }
    }

    func testWatchCommandsEncodeTypedStartPongAndSeatMessages() throws {
        let start = try LiveWatchCommand.startWatching(reconnect: false).encoded()
        let startObject = try XCTUnwrap(JSONSerialization.jsonObject(with: start) as? [String: Any])
        XCTAssertEqual(startObject["type"] as? String, "startWatching")
        XCTAssertEqual((startObject["data"] as? [String: Any])?["reconnect"] as? Bool, false)

        let pong = try LiveWatchCommand.pong.encoded()
        XCTAssertEqual((try JSONSerialization.jsonObject(with: pong) as? [String: String])?["type"], "pong")

        let keepSeat = try LiveWatchCommand.keepSeat.encoded()
        XCTAssertEqual((try JSONSerialization.jsonObject(with: keepSeat) as? [String: String])?["type"], "keepSeat")
    }

    func testWatchLifecycleDecodesSeatRoomPingAndFiniteControlState() throws {
        let seat = try LiveWatchMessage(data: data(#"{"type":"seat","data":{"keepIntervalSec":30}}"#))
        if case .seat(let interval) = seat {
            XCTAssertEqual(interval, 30)
        } else {
            XCTFail("expected seat")
        }

        let room = try LiveWatchMessage(data: data(#"{"type":"room","data":{"vposBaseTime":"2026-10-18T12:00:00.000+09:00","threadId":"thread-fixture","yourPostKey":"synthetic-key","messageServer":{"uri":"wss://example.invalid/message"}}}"#))
        guard case .room(let value) = room else { return XCTFail("expected room") }
        XCTAssertEqual(value.threadID, "thread-fixture")
        XCTAssertEqual(value.messageServerURL.scheme, "wss")
        XCTAssertNotNil(value.vposBaseTime)

        let handshake = try value.commentHandshakeData()
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: handshake) as? [[String: Any]])
        XCTAssertEqual(entries.count, 5)
        let thread = try XCTUnwrap(entries[2]["thread"] as? [String: Any])
        XCTAssertEqual(thread["version"] as? String, "20061206")
        XCTAssertEqual(thread["thread"] as? String, "thread-fixture")
        XCTAssertEqual(thread["threadkey"] as? String, "synthetic-key")
        XCTAssertEqual(thread["user_id"] as? String, "")
        XCTAssertEqual(thread["res_from"] as? Int, -100)

        let liveOnlyHandshake = try value.commentHandshakeData(resFrom: 0)
        let liveOnlyEntries = try XCTUnwrap(JSONSerialization.jsonObject(with: liveOnlyHandshake) as? [[String: Any]])
        let liveOnlyThread = try XCTUnwrap(liveOnlyEntries[2]["thread"] as? [String: Any])
        XCTAssertEqual(liveOnlyThread["res_from"] as? Int, 0)
        XCTAssertThrowsError(try value.commentHandshakeData(resFrom: -LiveCommentProtocol.maximumHistoryRequest - 1))
        XCTAssertThrowsError(try value.commentHandshakeData(resFrom: 1))

        let ping = try LiveWatchMessage(data: data(#"{"type":"ping"}"#))
        XCTAssertEqual(ping, .ping)
        let reconnect = try LiveWatchMessage(data: data(#"{"type":"reconnect","data":{"waitTimeSec":3}}"#))
        XCTAssertTrue(reconnect.isReconnectable)
        XCTAssertEqual(reconnect.uiMessage, "実況サーバーに再接続しています。")
    }

    func testWatchRejectsInvalidIntervalsThreadsAndRetryWaits() throws {
        let invalid = [
            #"{"type":"seat","data":{"keepIntervalSec":0}}"#,
            #"{"type":"seat","data":{"keepIntervalSec":601}}"#,
            #"{"type":"room","data":{"threadId":"","messageServer":{"uri":"wss://example.invalid/message"}}}"#,
            #"{"type":"reconnect","data":{"waitTimeSec":301}}"#
        ]
        for value in invalid {
            XCTAssertThrowsError(try LiveWatchMessage(data: data(value)))
        }
    }

    func testCommentChatMapsCommandsColorsAndPlaybackTime() throws {
        let message = try LiveCommentMessage(data: data(#"{"chat":{"thread":"thread-fixture","no":42,"date":1730000000.25,"content":"sample message","mail":"red ue big #00ff00 184","yourpost":0}}"#))
        guard case .chat(let comment) = message else { return XCTFail("expected chat") }
        XCTAssertEqual(comment.threadID, "thread-fixture")
        XCTAssertEqual(comment.number, 42)
        XCTAssertEqual(comment.serverTime, 1_730_000_000.25, accuracy: 0.0001)
        XCTAssertEqual(comment.position, .top)
        XCTAssertEqual(comment.size, .big)
        XCTAssertEqual(comment.colorRGB, 0x00_FF_00)
        XCTAssertFalse(comment.isYourPost)

        let ownPost = try LiveCommentMessage(data: data(#"{"chat":{"thread":"thread-fixture","no":43,"date":1730000001,"content":"own","yourpost":1}}"#))
        guard case .chat(let ownComment) = ownPost else { return XCTFail("expected own chat") }
        XCTAssertTrue(ownComment.isYourPost)

        let playback = try comment.playbackComment(at: 12.5)
        XCTAssertEqual(playback.time, 12.5, accuracy: 0.0001)
        XCTAssertEqual(playback.text, "sample message")
    }

    func testCommentMessageHandlesThreadPingHistoryAndUnknownWithoutBodyLogging() throws {
        let thread = try LiveCommentMessage(data: data(#"{"thread":{"resultcode":0}}"#))
        XCTAssertEqual(thread, .thread(resultCode: 0))
        XCTAssertEqual(try LiveCommentMessage(data: data(#"{"ping":{"content":"rf:0"}}"#)), .historyFinished)
        XCTAssertEqual(try LiveCommentMessage(data: data(#"{"ping":{"content":"other"}}"#)), .ping)
        XCTAssertEqual(try LiveCommentMessage(data: data(#"{"future":{}}"#)), .unknown)
        XCTAssertEqual(try LiveCommentMessage(data: data(#"{"chat":{"thread":"t","no":1,"date":1,"content":"/nicoad fixture","premium":3}}"#)), .ignored)
    }

    func testInvalidChatIsIgnoredAndNonOperatorSlashTextRemainsUsable() throws {
        let invalid = try LiveCommentMessage(data: data(#"{"chat":{"thread":"t","no":1,"date":"bad","content":"ignored"}}"#))
        XCTAssertEqual(invalid, .ignored)

        let normal = try LiveCommentMessage(data: data(#"{"chat":{"thread":"t","no":2,"date":2,"content":"/hello fixture","premium":1}}"#))
        guard case .chat(let comment) = normal else { return XCTFail("expected normal slash text") }
        XCTAssertEqual(comment.text, "/hello fixture")

        // An out-of-range JSON number must be ignored as an optional premium
        // value, rather than being converted through a trapping Int(Double).
        let hugePremium = try LiveCommentMessage(data: data(#"{"chat":{"thread":"t","no":3,"date":3,"content":"ordinary","premium":1e300}}"#))
        guard case .chat(let hugePremiumComment) = hugePremium else { return XCTFail("expected ordinary chat") }
        XCTAssertEqual(hugePremiumComment.text, "ordinary")
    }

    func testJSONDepthIgnoresBracesInsideEscapedStringsAndRejectsDeepObjects() throws {
        let escaped = try LiveCommentMessage(data: data(#"{"chat":{"thread":"t","no":1,"date":2,"content":"braces { } and \"quotes\""}}"#))
        guard case .chat(let comment) = escaped else { return XCTFail("expected escaped chat") }
        XCTAssertTrue(comment.text.contains("braces"))

        var deep = "{\"type\":\"future\",\"data\":"
        for _ in 0..<(LiveCommentProtocol.maximumJSONDepth + 2) { deep += "{" }
        deep += "0"
        for _ in 0..<(LiveCommentProtocol.maximumJSONDepth + 2) { deep += "}" }
        deep += "}"
        XCTAssertThrowsError(try LiveWatchMessage(data: data(deep))) { error in
            XCTAssertEqual(error as? LiveCommentError, .jsonTooDeep)
        }
    }

    func testFrameLimitAcceptsExactBoundaryAndRejectsOneByteOver() throws {
        let base = data(#"{"chat":{"thread":"t","no":1,"date":2,"content":"fixture"}}"#)
        var exact = base
        exact.append(Data(repeating: 0x20, count: LiveCommentProtocol.maximumFrameBytes - base.count))
        XCTAssertEqual(exact.count, LiveCommentProtocol.maximumFrameBytes)
        XCTAssertNoThrow(try LiveCommentMessage(data: exact))

        var over = exact
        over.append(0x20)
        XCTAssertThrowsError(try LiveCommentMessage(data: over)) { error in
            XCTAssertEqual(error as? LiveCommentError, .frameTooLarge)
        }
    }

    func testControlCodesMapToReconnectPolicyWithoutRawCodeInErrorDescription() throws {
        let permanent = try LiveWatchMessage(data: data(#"{"type":"error","data":{"code":"NO_PERMISSION"}}"#))
        XCTAssertFalse(permanent.isReconnectable)
        XCTAssertEqual(permanent.uiMessage, "実況サーバーへのアクセス権限がありません。")

        let temporary = try LiveWatchMessage(data: data(#"{"type":"disconnect","data":{"reason":"PING_TIMEOUT"}}"#))
        XCTAssertTrue(temporary.isReconnectable)
        XCTAssertEqual(temporary.uiMessage, "実況サーバーとの接続確認に失敗しました。")
        XCTAssertFalse(LiveCommentError.invalidMessage.localizedDescription.contains("PING_TIMEOUT"))
    }
}
