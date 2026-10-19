import Combine
import Foundation
import RingonomiCore

/// Owns the EPGStation live-stream request and keep-alive lifetimes.
///
/// A stream identifier belongs to one start request.  Every replacement gets a
/// new generation so a late response cannot replace the selected quality or
/// restart keep-alive for an older stream.
@MainActor
final class EPGStationLivePlaybackStore: ObservableObject {
    @Published private(set) var qualities: [EPGStationLiveQuality] = []
    @Published private(set) var selectedQuality: EPGStationLiveQuality?
    @Published private(set) var stream: EPGStationLiveStream?
    @Published private(set) var streamRevision = 0
    @Published private(set) var isLoading = false
    @Published private(set) var awaitingQualitySelection = false
    @Published private(set) var isSuspended = false
    @Published private(set) var error: String?

    private var request: Task<Void, Never>?
    private var keepAlive: Task<Void, Never>?
    private var generation = UUID()
    private var client: EPGStationClient?
    private var address = ""
    private var channelID: Int?

    deinit {
        request?.cancel()
        keepAlive?.cancel()
    }

    func load(address: String, channelID: Int) {
        let requestedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.address == requestedAddress,
           self.channelID == channelID,
           (isLoading || stream != nil || awaitingQualitySelection) {
            return
        }

        request?.cancel()
        keepAlive?.cancel()
        keepAlive = nil
        let expected = UUID()
        generation = expected
        self.address = requestedAddress
        self.channelID = channelID
        client = nil
        qualities = []
        selectedQuality = nil
        stream = nil
        error = nil
        awaitingQualitySelection = false
        isSuspended = false
        isLoading = true

        request = Task { @MainActor [weak self] in
            do {
                let client = try EPGStationClient(address: requestedAddress)
                let loaded = try await client.liveQualities()
                try Task.checkCancellation()
                guard let self, self.generation == expected else { return }
                guard !loaded.isEmpty else {
                    self.isLoading = false
                    self.error = "利用できる画質がありません。接続先の設定を確認してください。"
                    return
                }

                self.client = client
                self.qualities = loaded
                guard let initial = loaded.first(where: { $0.isUnconverted }) else {
                    // Do not silently start an encoder on a recording server.
                    // The user must explicitly choose a converted quality.
                    self.isLoading = false
                    self.awaitingQualitySelection = true
#if DEBUG
                    print("RingonomiEPGStationLive: awaitingQualitySelection")
#endif
                    return
                }
                guard let channelID = self.channelID else {
                    self.isLoading = false
                    self.error = "視聴するチャンネルが不正です。"
                    return
                }
                let stream = try await client.startLiveStream(channelID: channelID, quality: initial)
                try Task.checkCancellation()
                guard self.generation == expected, !self.isSuspended else { return }
                self.selectedQuality = initial
#if DEBUG
                print("RingonomiEPGStationLive: selected=\(initial.id) unconverted=\(initial.isUnconverted)")
#endif
                self.stream = stream
                self.streamRevision &+= 1
                self.awaitingQualitySelection = false
                self.error = nil
                self.isLoading = false
                self.startKeepAlive(client: client, stream: stream, quality: initial, generation: expected)
            } catch is CancellationError {
                guard let self, self.generation == expected else { return }
                self.isLoading = false
            } catch {
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.stream = nil
                self.awaitingQualitySelection = false
                self.error = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    func selectQuality(_ quality: EPGStationLiveQuality, force: Bool = false) {
        guard !isSuspended,
              qualities.contains(where: { $0.id == quality.id }) else { return }
        if !force, selectedQuality?.id == quality.id, stream != nil, error == nil { return }
        guard let client, let channelID else {
            error = "EPGStationの接続を準備できません。再試行してください。"
            return
        }

        request?.cancel()
        keepAlive?.cancel()
        keepAlive = nil
        let expected = UUID()
        generation = expected
        selectedQuality = quality
        awaitingQualitySelection = false
        error = nil
        isLoading = true

        request = Task { @MainActor [weak self] in
            do {
                let stream = try await client.startLiveStream(channelID: channelID, quality: quality)
                try Task.checkCancellation()
                guard let self, self.generation == expected, !self.isSuspended else { return }
                self.stream = stream
                self.streamRevision &+= 1
#if DEBUG
                print("RingonomiEPGStationLive: selected=\(quality.id) unconverted=\(quality.isUnconverted) revision=\(self.streamRevision)")
#endif
                self.error = nil
                self.isLoading = false
                self.startKeepAlive(client: client, stream: stream, quality: quality, generation: expected)
            } catch is CancellationError {
                guard let self, self.generation == expected else { return }
                self.isLoading = false
            } catch {
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    func retry() {
        if let selectedQuality {
            selectQuality(selectedQuality, force: true)
        } else if let channelID {
            load(address: address, channelID: channelID)
        }
    }

    /// Start a new server stream for the selected quality.  HLS stream URLs
    /// identify a server-side session, so resuming a paused HLS player must
    /// not rely on the old playlist remaining alive.
    func refreshSelectedQuality() {
        guard let selectedQuality else { return }
        selectQuality(selectedQuality, force: true)
    }

    func stopKeepAlive() {
        keepAlive?.cancel()
        keepAlive = nil
    }

    /// Stop network tasks while retaining the selected quality for a fresh
    /// stream after Home/background.  The decoder is suspended by the view.
    func suspendForBackground() {
        guard !isSuspended else { return }
        isSuspended = true
        generation = UUID()
        request?.cancel()
        request = nil
        keepAlive?.cancel()
        keepAlive = nil
        isLoading = false
    }

    func resumeFromBackground() {
        guard isSuspended else { return }
        isSuspended = false
        if let selectedQuality {
            selectQuality(selectedQuality, force: true)
        } else if let channelID {
            load(address: address, channelID: channelID)
        }
    }

    func stop() {
        generation = UUID()
        request?.cancel()
        request = nil
        keepAlive?.cancel()
        keepAlive = nil
        client = nil
        address = ""
        channelID = nil
        qualities = []
        selectedQuality = nil
        stream = nil
        error = nil
        isLoading = false
        awaitingQualitySelection = false
        isSuspended = false
    }

    private func startKeepAlive(
        client: EPGStationClient,
        stream: EPGStationLiveStream,
        quality: EPGStationLiveQuality,
        generation expected: UUID
    ) {
        keepAlive?.cancel()
        guard quality.format == .hls, let streamID = stream.streamID else { return }

        keepAlive = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(4))
                    try Task.checkCancellation()
                    try await client.keepLiveStream(id: streamID)
                    try Task.checkCancellation()
                    guard let self,
                          self.generation == expected,
                          self.stream?.streamID == streamID,
                          !self.isSuspended else { return }
                } catch is CancellationError {
                    return
                } catch {
                    guard let self,
                          self.generation == expected,
                          !Task.isCancelled else { return }
                    self.error = "配信の維持に失敗しました。再試行してください。"
                    self.isLoading = false
                    self.keepAlive = nil
                    return
                }
            }
        }
    }
}
