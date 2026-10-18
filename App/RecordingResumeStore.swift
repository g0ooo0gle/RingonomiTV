import Foundation
import RingonomiCore
import SwiftUI

/// このApple TVで再生した位置だけを保存する。
@MainActor
final class RecordingResumeStore: ObservableObject {
    @Published private(set) var revision = 0
    private let defaults: UserDefaults
    private let storageKey = "recordingResume.v1"
    private var archive: RecordingResumeArchive

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        archive = defaults.data(forKey: storageKey).flatMap {
            try? JSONDecoder().decode(RecordingResumeArchive.self, from: $0)
        } ?? RecordingResumeArchive()
    }

    func position(for id: RecordingResumeID, duration: Double?, status: String?) -> Double? {
        guard let entry = archive.entry(for: id.storageKey) else { return nil }
        return RecordingResumePolicy.candidate(entry: entry, duration: duration, status: status)
    }

    func identity(for recording: Recording, client: RingonomiClient) -> RecordingResumeID? {
        // 開始時刻がない応答は、再利用されたファイルIDと区別できないため保存しない。
        guard let start = recording.startTime?.trimmingCharacters(in: .whitespacesAndNewlines),
              !start.isEmpty else { return nil }
        return RecordingResumeID(serverURL: client.baseURL, videoID: recording.recordedVideo.id,
                                 recordingStartTime: start)
    }

    func position(for recording: Recording, client: RingonomiClient) -> Double? {
        guard let id = identity(for: recording, client: client) else { return nil }
        return position(for: id, duration: recording.recordedVideo.duration, status: recording.recordedVideo.status)
    }

    func save(_ id: RecordingResumeID, seconds: Double, duration: Double?, status: String?, reachedEnd: Bool) {
        guard let seconds = RecordingResumePolicy.clamp(seconds: seconds, duration: duration) else { return }
        if seconds < 5 || RecordingResumePolicy.shouldClear(
            seconds: seconds, duration: duration, status: status, reachedEnd: reachedEnd
        ) {
            guard archive.entry(for: id.storageKey) != nil else { return }
            archive.remove(for: id.storageKey)
        } else {
            archive.set(RecordingResumeEntry(seconds: seconds), for: id.storageKey)
        }
        guard let data = try? JSONEncoder().encode(archive) else { return }
        defaults.set(data, forKey: storageKey)
        revision &+= 1
    }
}
