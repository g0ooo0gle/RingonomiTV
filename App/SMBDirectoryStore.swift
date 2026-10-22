import Combine
import Foundation
import RingonomiCore

/// Keeps native directory requests separate from navigation and saved shares.
@MainActor
final class SMBDirectoryStore: ObservableObject {
    @Published private(set) var entries: [SMBLibraryEntry] = []
    @Published private(set) var loading = false
    @Published private(set) var cancelled = false
    @Published private(set) var error: String?
    @Published private(set) var warning: String?
    @Published private(set) var loadedPath: SMBRelativePath?

    private let bridge = RNGSMBDirectoryBridge()
    private var request: RNGSMBDirectoryRequest?
    private var generation = UUID()

    func load(connection: SMBConnection, path: SMBRelativePath,
              credentials: SMBCredentials?) {
        cancel(clear: true)
        let expected = UUID()
        generation = expected
        do {
            let url = try connection.url(for: path)
            loading = true
            request = bridge.listDirectory(at: url,
                username: credentials?.username, password: credentials?.password,
                domain: credentials?.domain
            ) { [weak self] items, nativeError in
                // The bridge delivers completion on the main queue, including
                // immediate failures. Do not transfer native objects to a Task.
                MainActor.assumeIsolated {
                    guard let self, self.generation == expected else { return }
                    self.request = nil
                    self.loading = false
                    if let nativeError {
                        self.error = nativeError.localizedDescription
                        return
                    }
                    do {
                        let result = try Self.validated(items ?? [], connection: connection, parent: path)
                        self.entries = SMBLibraryEntry.sorted(result.entries)
                        self.warning = result.skipped > 0
                            ? "表示できない項目を\(result.skipped)件除外しました。" : nil
                        self.loadedPath = path
                    } catch {
                        self.error = "フォルダーの内容を読み込めませんでした。再試行してください。"
                    }
                }
            }
        } catch {
            self.error = "共有のパスを開けませんでした。接続設定を確認してください。"
        }
    }

    func cancel(clear: Bool = false) {
        let wasLoading = loading
        generation = UUID()
        request?.cancel()
        request = nil
        loading = false
        if clear {
            entries = []
            loadedPath = nil
            error = nil
            warning = nil
            cancelled = false
        } else if wasLoading {
            cancelled = true
        }
    }

    func reportCredentialFailure() {
        cancel(clear: true)
        error = "保存した認証情報を読み込めませんでした。共有の認証設定を確認して再試行してください。"
    }

    private static func validated(
        _ items: [RNGSMBDirectoryItem], connection: SMBConnection, parent: SMBRelativePath
    ) throws -> (entries: [SMBLibraryEntry], skipped: Int) {
        guard items.count <= 4_096 else { throw SMBError.invalidEntry }
        var entries: [SMBLibraryEntry] = []
        var paths = Set<SMBRelativePath>()
        var skipped = 0
        for item in items {
            guard let path = try? connection.relativePath(for: item.url),
                  path.parent() == parent,
                  let name = path.components.last,
                  name == item.name,
                  paths.insert(path).inserted,
                  let entry = try? SMBLibraryEntry(name: name, path: path,
                      isDirectory: item.type == .directory) else {
                skipped += 1
                continue
            }
            if entry.isDirectory || entry.isVideo { entries.append(entry) }
        }
        return (entries, skipped)
    }
}
