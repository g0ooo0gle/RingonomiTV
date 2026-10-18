import Foundation
import RingonomiCore

func require(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}
for address in ["192.0.2.4", "ftp://server", "https://test-user@example.invalid", "https://server?q=1"] {
    do {
        _ = try RingonomiClient(address: address)
        fatalError("Invalid address accepted")
    } catch is ConnectionError {} catch { fatalError("Unexpected error") }
}
let decoder = JSONDecoder()
decoder.keyDecodingStrategy = .convertFromSnakeCase
let data = Data(#"{"id":"NID1-SID2","display_channel_id":"gr011","name":"放送局","is_watchable":true,"is_display":true,"program_present":{"id":"event1","title":"番組","description":"内容"}}"#.utf8)
let channel = try decoder.decode(Channel.self, from: data)
let client = try RingonomiClient(address: "http://localhost:7000/backend/")
require(channel.programPresent?.title == "番組", "Program decode failed")
require(client.liveURL(channel: channel, quality: "720p").absoluteString == "http://localhost:7000/backend/api/streams/live/gr011/720p/mpegts", "Live path mismatch")
let recording = client.recordingURL(id: 12, session: "a&b", quality: "720p")
require(URLComponents(url: recording, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "a&b", "Session query encoding failed")
print("PASS: invalid URLs, channel/program decoding, live endpoint, session encoding")

let browserClient = try RingonomiClient(address: "https://localhost:7000/tv/")
require(browserClient.endpoint(["api", "channels"]).absoluteString == "https://localhost:7000/api/channels", "Browser URL normalization failed")
let subpathClient = try RingonomiClient(address: "https://localhost/proxy/tv/")
require(subpathClient.endpoint(["api", "channels"]).path == "/proxy/api/channels", "Proxy prefix lost")
if CommandLine.arguments.count == 3 {
    let channelData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let groups = try decoder.decode([String: [Channel]].self, from: channelData)
    let videoData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    let videos = try decoder.decode(RecordingsResponse.self, from: videoData)
    print("PASS: real server payloads: \(groups.values.reduce(0) { $0 + $1.count }) channels, \(videos.recordedPrograms.count) recording entries, total \(videos.total)")
}
