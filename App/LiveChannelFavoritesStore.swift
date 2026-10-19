import Combine
import Foundation
import RingonomiCore

/// Owns the selected server namespace for live-channel favorites.
///
/// The archive contains only normalized server keys and channel identifiers.
/// The configured address is kept in memory solely so `reset()` can restore
/// the current UI namespace; it is never written to UserDefaults.
@MainActor
final class LiveChannelFavoritesStore: ObservableObject {
    private static let storageKey = "liveChannelFavorites.v1"
    private static let maximumArchiveBytes = 256 * 1024

    @Published private(set) var favoriteIDs: Set<String> = []
    @Published private(set) var error: String?
    @Published private(set) var canEdit = false
    @Published private(set) var needsReset = false

    private let defaults: UserDefaults
    private var archive: LiveChannelFavoritesArchive
    private var archiveIsCorrupt = false
    private var configuredAddress: String?
    private var configuredServerKey: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.archive = LiveChannelFavoritesArchive()
        loadArchiveOnce()
    }

    /// Select the server namespace shown by the current screen.
    ///
    /// Switching servers clears the previous IDs before the new namespace is
    /// read, so favorites can never briefly appear under the wrong backend.
    func configure(address: String) {
        configuredAddress = address
        configuredServerKey = nil
        favoriteIDs = []
        canEdit = false
        error = nil

        guard !archiveIsCorrupt else {
            showCorruptArchive()
            return
        }

        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            configuredServerKey = nil
            favoriteIDs = []
            canEdit = false
            needsReset = false
            return
        }

        do {
            let serverKey = try LiveChannelFavoritesArchive.serverKey(address: address)
            configuredServerKey = serverKey
            favoriteIDs = archive.favoriteIDs(serverKey: serverKey)
            canEdit = true
            needsReset = false
        } catch {
            // The backend's URL is intentionally not included in the UI error.
            configuredServerKey = nil
            favoriteIDs = []
            canEdit = false
            needsReset = false
            self.error = "お気に入りを読み込めません。接続先を確認してください。"
        }
    }

    /// Toggle one channel in the currently configured server namespace.
    ///
    /// All mutations happen on a copy. The published state and the original
    /// archive are updated only after validation, encoding, and the size check
    /// have succeeded.
    func toggle(channelID: String) {
        guard !archiveIsCorrupt, canEdit, let serverKey = configuredServerKey else {
            if archiveIsCorrupt { showCorruptArchive() }
            else { error = "お気に入りを変更できません。接続先を確認してください。" }
            return
        }

        let wasFavorite = favoriteIDs.contains(channelID)
        var candidate = archive
        do {
            try candidate.setFavorite(
                channelID,
                isFavorite: !wasFavorite,
                serverKey: serverKey
            )
            let data = try candidate.data()
            guard data.count <= Self.maximumArchiveBytes else {
                throw LiveChannelFavoritesStoreFailure.archiveTooLarge
            }

            defaults.set(data, forKey: Self.storageKey)
            archive = candidate
            favoriteIDs = candidate.favoriteIDs(serverKey: serverKey)
            error = nil
            needsReset = false
        } catch let failure as LiveChannelFavoritesError {
            self.error = failure.errorDescription ?? "お気に入りを保存できませんでした。"
        } catch {
            // Keep the prior archive and favoriteIDs intact. A size or model
            // validation failure should still leave removal and retry usable.
            self.error = "お気に入りを保存できませんでした。"
        }
    }

    /// Explicitly discard the complete favorites archive and restore the
    /// currently configured server namespace. Other UserDefaults are untouched.
    func reset() {
        defaults.removeObject(forKey: Self.storageKey)
        archive = LiveChannelFavoritesArchive()
        archiveIsCorrupt = false
        favoriteIDs = []
        canEdit = false
        needsReset = false
        error = nil

        guard let configuredAddress else { return }
        configure(address: configuredAddress)
    }

    private func loadArchiveOnce() {
        guard let stored = defaults.object(forKey: Self.storageKey) else { return }
        guard let data = stored as? Data else {
            // A value of the wrong UserDefaults type is still occupied
            // storage. Treat it as corruption so a later toggle cannot
            // silently replace the original value.
            showCorruptArchive()
            return
        }
        guard data.count <= Self.maximumArchiveBytes else {
            showCorruptArchive()
            return
        }

        do {
            archive = try LiveChannelFavoritesArchive(data: data)
        } catch {
            // Preserve the original bytes. Only an explicit reset may replace
            // a corrupt archive.
            showCorruptArchive()
        }
    }

    private func showCorruptArchive() {
        archiveIsCorrupt = true
        favoriteIDs = []
        canEdit = false
        needsReset = true
        error = "お気に入りデータを読み込めません。リセットしてください。"
    }
}

private enum LiveChannelFavoritesStoreFailure: Error {
    case archiveTooLarge
}
