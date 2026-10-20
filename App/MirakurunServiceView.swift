import SwiftUI
import RingonomiCore

@MainActor
final class MirakurunServiceStore: ObservableObject {
    @Published private(set) var services: [MirakurunService] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var loadedAddress: String?

    private var request: Task<Void, Never>?
    private var generation = UUID()

    func load(address: String) {
        request?.cancel()
        let requestedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedGeneration = UUID()
        generation = expectedGeneration
        services = []
        loadedAddress = nil
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
                loadedAddress = requestedAddress
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
#if DEBUG
    @State private var debugPlaybackHandled = false
#endif
    @StateObject private var store = MirakurunServiceStore()
    @StateObject private var playbackIdleTimer = PlaybackIdleTimer()

    private var effectiveAddress: String {
#if DEBUG
        return runtimeAddress ?? address
#else
        return address
#endif
    }

#if DEBUG
    private var runtimeAddress: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--mirakurun-url"),
              index + 1 < arguments.count else { return nil }
        let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private var debugServiceID: Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--play-mirakurun-service"),
              index + 1 < arguments.count else { return nil }
        return Int(arguments[index + 1])
    }
#endif

    var body: some View {
        Form {
            AppSection("Mirakurun接続") {
                TextField("Mirakurun URL（例： http://ホスト:40772）", text: $draftAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("接続してサービスを読み込む", action: connect)
                    .disabled(store.isLoading)

                if store.isLoading {
                    ProgressView("サービスを読み込んでいます…")
                }

                Text("視聴したいMirakurunの接続先を入力してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            AppSection("サービス") {
                NavigationLink("番組表から探す") { MirakurunProgramGuideView() }
                if effectiveAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("接続先を入力して、サービスを読み込んでください。")
                        .foregroundStyle(.secondary)
                } else if store.isLoading && store.services.isEmpty {
                    Text("サービス一覧を準備しています…")
                        .foregroundStyle(.secondary)
                } else if let error = store.error {
                    Text(error)
                        .foregroundStyle(.red)
                    Button("再試行") { store.load(address: effectiveAddress) }
                        .disabled(store.isLoading || effectiveAddress.isEmpty)
                } else if store.services.isEmpty {
                    Text("サービスがありません。接続先を確認して再読み込みしてください。")
                        .foregroundStyle(.secondary)
                    Button("再読み込み") { store.load(address: effectiveAddress) }
                        .disabled(store.isLoading || effectiveAddress.isEmpty)
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
                AppSection("接続エラー") {
                    Text(inputError)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Mirakurun直接視聴")
        .onAppear {
            if !didPrepareDraft {
                draftAddress = effectiveAddress
                didPrepareDraft = true
            }
            if !effectiveAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               store.loadedAddress != effectiveAddress, !store.isLoading {
                store.load(address: effectiveAddress)
            }
#if DEBUG
            openDebugServiceIfNeeded()
#endif
        }
        .onDisappear {
            store.cancel()
        }
        .onChange(of: effectiveAddress) { _, next in
            playback = nil
            inputError = nil
            draftAddress = next
            if !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.load(address: next)
            } else {
                store.cancel()
            }
        }
        .fullScreenCover(item: $playback) { item in
            MirakurunPlaybackView(item: item) { needsDisplay in
                guard playback?.id == item.id else { return }
                playbackIdleTimer.setNeedsContinuousDisplay(needsDisplay)
            }
        }
        .onChange(of: playback?.id) { _, id in
            if id == nil {
                playbackIdleTimer.setNeedsContinuousDisplay(false)
            }
        }
#if DEBUG
        .onChange(of: store.services) { _, _ in
            openDebugServiceIfNeeded()
        }
#endif
    }

    private func connect() {
        let next = draftAddress.trimmingCharacters(in: .whitespacesAndNewlines)
#if DEBUG
        if let runtimeAddress {
            guard !runtimeAddress.isEmpty else {
                inputError = "Mirakurunの接続先を指定してください。"
                return
            }
            inputError = nil
            store.load(address: runtimeAddress)
            return
        }
#endif
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
            let client = try MirakurunClient(address: effectiveAddress)
            inputError = nil
            playback = MirakurunPlaybackSelection(
                url: client.streamURL(for: service),
                title: displayName(for: service)
            )
        } catch {
            inputError = error.localizedDescription
        }
    }

#if DEBUG
    private func openDebugServiceIfNeeded() {
        guard !debugPlaybackHandled, let serviceID = debugServiceID,
              let service = store.services.first(where: { $0.id == serviceID }) else { return }
        debugPlaybackHandled = true
        open(service)
    }
#endif

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
