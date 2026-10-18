import SwiftUI
import RingonomiCore

@MainActor
final class MirakurunServiceStore: ObservableObject {
    @Published private(set) var services: [MirakurunService] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private var request: Task<Void, Never>?
    private var generation = UUID()

    func load(address: String) {
        request?.cancel()
        let requestedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedGeneration = UUID()
        generation = expectedGeneration
        services = []
        error = nil
        isLoading = true

        request = Task { @MainActor [weak self] in
            do {
                let client = try MirakurunClient(address: requestedAddress)
                let loaded = try await client.services()
                try Task.checkCancellation()
                guard let self, self.generation == expectedGeneration else { return }
                services = loaded.sorted {
                    if $0.name != $1.name {
                        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                    return $0.id < $1.id
                }
                isLoading = false
            } catch is CancellationError {
                guard let self, self.generation == expectedGeneration else { return }
                isLoading = false
            } catch {
                guard let self, self.generation == expectedGeneration else { return }
                services = []
                self.error = error.localizedDescription
                isLoading = false
            }
        }
    }

    func cancel() {
        request?.cancel()
        request = nil
        generation = UUID()
        isLoading = false
    }
}

struct MirakurunServiceView: View {
    @AppStorage("mirakurunAddress") private var address = ""
    @State private var draftAddress = ""
    @State private var didPrepareDraft = false
    @State private var playback: MirakurunPlaybackSelection?
    @State private var inputError: String?
    @StateObject private var store = MirakurunServiceStore()
    @StateObject private var playbackIdleTimer = PlaybackIdleTimer()

    var body: some View {
        Form {
            Section("Mirakurun接続") {
                TextField("Mirakurun URL（例： http://ホスト:40772）", text: $draftAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("接続してサービスを読み込む", action: connect)
                    .disabled(store.isLoading)

                if store.isLoading {
                    ProgressView("サービスを読み込んでいます…")
                }

                Text("MirakurunのサービスAPIを使用します。KonomiTVのアカウントや接続設定は使いません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("サービス") {
                if store.isLoading && store.services.isEmpty {
                    Text("サービス一覧を準備しています…")
                        .foregroundStyle(.secondary)
                } else if let error = store.error {
                    Text(error)
                        .foregroundStyle(.red)
                    Button("再試行") { store.load(address: address) }
                        .disabled(store.isLoading || address.isEmpty)
                } else if store.services.isEmpty {
                    Text("サービスがありません。接続先を確認して再読み込みしてください。")
                        .foregroundStyle(.secondary)
                    Button("再読み込み") { store.load(address: address) }
                        .disabled(store.isLoading || address.isEmpty)
                } else {
                    ForEach(store.services) { service in
                        Button {
                            open(service)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(displayName(for: service))
                                    .font(.headline)
                                Text(serviceDetail(for: service))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(store.isLoading)
                    }
                }
            }

            if let inputError {
                Section("接続エラー") {
                    Text(inputError)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Mirakurun直接視聴")
        .onAppear {
            if !didPrepareDraft {
                draftAddress = address
                didPrepareDraft = true
            }
            if !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               store.services.isEmpty, !store.isLoading, store.error == nil {
                store.load(address: address)
            }
        }
        .onDisappear {
            store.cancel()
        }
        .fullScreenCover(item: $playback) { item in
            MirakurunPlaybackView(item: item) { needsDisplay in
                playbackIdleTimer.setNeedsContinuousDisplay(needsDisplay)
            }
        }
    }

    private func connect() {
        let next = draftAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try MirakurunClient(address: next)
            inputError = nil
            address = next
            store.load(address: next)
        } catch {
            inputError = error.localizedDescription
        }
    }

    private func open(_ service: MirakurunService) {
        do {
            let client = try MirakurunClient(address: address)
            inputError = nil
            playback = MirakurunPlaybackSelection(
                url: client.streamURL(for: service),
                title: displayName(for: service)
            )
        } catch {
            inputError = error.localizedDescription
        }
    }

    private func displayName(for service: MirakurunService) -> String {
        let name = service.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        if let channelName = service.channel?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !channelName.isEmpty {
            return channelName
        }
        return "サービス \(service.id)"
    }

    private func serviceDetail(for service: MirakurunService) -> String {
        if let channel = service.channel {
            return "\(channel.type) · \(channel.channel)"
        }
        return "サービスID \(service.id)"
    }
}
