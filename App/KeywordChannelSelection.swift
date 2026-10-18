import SwiftUI
import RingonomiCore

struct KeywordChannelSelection: View {
    let address: String
    @Binding var selection: [ProgramSearchService]?
    @State private var channels: [GuideChannel] = []
    @State private var loading = false
    @State private var error: String?
    @State private var revision = 0

    var body: some View {
        List {
            Toggle("全チャンネル", isOn: Binding(get: { selection == nil }, set: { selection = $0 ? nil : [] }))
            if selection != nil {
                ForEach(channels) { channel in
                    if let service = service(for: channel) {
                        Toggle(channel.name + "（" + channel.type + "）", isOn: Binding(
                            get: { selection?.contains(where: { key($0) == key(service) }) == true },
                            set: { selected in
                                var values = selection ?? []
                                values.removeAll { key($0) == key(service) }
                                if selected { values.append(service) }
                                selection = values
                            }))
                    }
                }
            }
            if let error {
                Text(error).foregroundStyle(.red)
                Button("再試行") { revision += 1 }
            }
        }
        .navigationTitle("対象チャンネル")
        .overlay { if loading { ProgressView("チャンネルを読み込んでいます…") } }
        .task(id: "\(address)|\(revision)") { await load() }
    }

    private func service(for channel: GuideChannel) -> ProgramSearchService? {
        guard let network = channel.networkId, let stream = channel.transportStreamId, let service = channel.serviceId else { return nil }
        return ProgramSearchService(networkID: network, transportStreamID: stream, serviceID: service)
    }

    private func key(_ service: ProgramSearchService) -> String {
        "\(service.networkID):\(service.transportStreamID):\(service.serviceID)"
    }

    @MainActor private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let response = try await RingonomiClient(address: address).fetch(["api", "channels"], as: [String: [GuideChannel]].self)
            guard !Task.isCancelled else { return }
            var seen = Set<String>()
            channels = ["GR", "BS", "CS", "CATV", "SKY", "BS4K"].flatMap { response[$0] ?? [] }
                .filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "チャンネルを読み込めませんでした。\(error.localizedDescription)"
        }
    }
}
