import Foundation
import RingonomiCore
import SwiftUI

/// Local positions are separate from server recording IDs and credentials.
@MainActor
final class SMBResumeStore: ObservableObject {
    private let defaults: UserDefaults
    private let storageKey: String
    private var archive: SMBResumeArchive

    init(defaults: UserDefaults = .standard, storageKey: String = "smbResume.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        archive = defaults.data(forKey: storageKey).flatMap {
            try? SMBResumeArchive(data: $0)
        } ?? SMBResumeArchive()
    }

    static func playbackStore() -> SMBResumeStore {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--smb-url") {
            let key = "smbResume.fixture.v1"
            if arguments.contains("--reset-smb-resume") {
                UserDefaults.standard.removeObject(forKey: key)
            }
            return SMBResumeStore(storageKey: key)
        }
#endif
        return SMBResumeStore()
    }

    func bookmark(for id: SMBResumeID) -> SMBResumeBookmark? {
        guard let bookmark = archive.entry(for: id),
              SMBResumePolicy.candidate(bookmark: bookmark) != nil else { return nil }
        return bookmark
    }

    func save(_ id: SMBResumeID, seconds: Double, duration: Double?, reachedEnd: Bool) {
        if reachedEnd {
            remove(id)
            return
        }
        guard seconds.isFinite, seconds >= 0,
              let duration, duration.isFinite, duration > 0 else { return }
        if seconds < SMBResumePolicy.minimumResumeSeconds {
            remove(id)
        } else if let bookmark = SMBResumePolicy.validatedBookmark(
            seconds: seconds, duration: duration, updatedAt: Date()
        ) {
            guard (try? archive.set(bookmark, for: id)) != nil else { return }
            persist()
        }
    }

    func remove(_ id: SMBResumeID) {
        guard archive.entry(for: id) != nil else { return }
        archive.remove(for: id)
        persist()
    }

    private func persist() {
        if archive.entries.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else if let data = try? archive.data() {
            defaults.set(data, forKey: storageKey)
        }
    }
}
