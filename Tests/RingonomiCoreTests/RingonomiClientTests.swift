import XCTest
@testable import RingonomiCore
final class RingonomiClientTests: XCTestCase {
    func testRejectsAmbiguousAndCredentialAddresses() {
        for address in ["192.0.2.4", "ftp://server", "https://test-user@example.invalid", "https://server?q=1"] {
            XCTAssertThrowsError(try RingonomiClient(address: address))
        }
    }
    func testAndroidChannelContractAndLivePath() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let data = Data(#"{"id":"NID1-SID2","display_channel_id":"gr011","name":"放送局","is_watchable":true,"is_display":true,"program_present":{"id":"event1","title":"番組","description":"内容"}}"#.utf8)
        let channel = try decoder.decode(Channel.self, from: data)
        let client = try RingonomiClient(address: "http://localhost:7000/backend/")
        XCTAssertEqual(client.liveURL(channel: channel, quality: "720p").absoluteString, "http://localhost:7000/backend/api/streams/live/gr011/720p/mpegts")
        XCTAssertEqual(channel.programPresent?.title, "番組")
    }
    func testSessionIsQueryEncoded() throws {
        let client = try RingonomiClient(address: "https://localhost")
        let url = client.recordingURL(id: 12, session: "a&b", quality: "720p")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "a&b")
    }
    func testRecordingUsesProgramIDAndSharesSessionAcrossPlaylistAndHeartbeat() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let data = Data(#"{"id":7,"title":"録画","description":"番組","is_free":true,"recorded_video":{"id":42,"duration":75.5}}"#.utf8)
        let recording = try decoder.decode(Recording.self, from: data)
        XCTAssertEqual(recording.id, 7)
        XCTAssertEqual(recording.recordedVideo.id, 42)
        XCTAssertEqual(recording.recordedVideo.duration, 75.5)
        let client = try RingonomiClient(address: "https://localhost/proxy/")
        let session = "test&session=1"
        let playlist = client.recordingURL(id: recording.playbackID, session: session, quality: "540p")
        let heartbeat = client.recordingKeepAliveURL(id: recording.playbackID, session: session, quality: "540p")
        XCTAssertEqual(playlist.path, "/proxy/api/streams/video/7/540p/playlist")
        XCTAssertEqual(heartbeat.path, "/proxy/api/streams/video/7/540p/keep-alive")
        for url in [playlist, heartbeat] {
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "session_id", value: session)])
        }
    }
}
