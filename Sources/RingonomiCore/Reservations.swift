import Foundation

// MARK: - Lossless JSON values and recording settings

/// JSON value used to preserve server fields that this client does not yet
/// understand. This is intentionally part of the public model so a settings
/// editor can round-trip a newer server response without deleting fields.
public enum RawJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([RawJSONValue])
    case object([String: RawJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RawJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: RawJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public struct RecordingFolder: Codable, Sendable, Equatable {
    /// Raw snake_case fields, including fields introduced by newer servers.
    public private(set) var rawValues: [String: RawJSONValue]

    public init(
        recordingFolderPath: String = "",
        recordingFileNameTemplate: String? = nil,
        isOnesegSeparateRecordingFolder: Bool = false,
        rawValues: [String: RawJSONValue] = [:]
    ) {
        var values: [String: RawJSONValue] = [
            "recording_folder_path": .string(recordingFolderPath),
            "recording_file_name_template": recordingFileNameTemplate.map(RawJSONValue.string) ?? .null,
            "is_oneseg_separate_recording_folder": .bool(isOnesegSeparateRecordingFolder)
        ]
        for (key, value) in rawValues { values[key] = value }
        self.rawValues = values
    }

    init(rawValues: [String: RawJSONValue]) {
        self.init(rawValues: rawValues, mergingDefaults: true)
    }

    private init(rawValues: [String: RawJSONValue], mergingDefaults: Bool) {
        if mergingDefaults {
            var values: [String: RawJSONValue] = [
                "recording_folder_path": .string(""),
                "recording_file_name_template": .null,
                "is_oneseg_separate_recording_folder": .bool(false)
            ]
            for (key, value) in rawValues { values[key] = value }
            self.rawValues = values
        } else {
            self.rawValues = rawValues
        }
    }

    public var recordingFolderPath: String {
        get { rawValues["recording_folder_path"]?.stringValue ?? "" }
        set { rawValues["recording_folder_path"] = .string(newValue) }
    }

    public var recordingFileNameTemplate: String? {
        get { rawValues["recording_file_name_template"]?.nullableStringValue }
        set { rawValues["recording_file_name_template"] = newValue.map(RawJSONValue.string) ?? .null }
    }

    public var isOnesegSeparateRecordingFolder: Bool {
        get { rawValues["is_oneseg_separate_recording_folder"]?.boolValue ?? false }
        set { rawValues["is_oneseg_separate_recording_folder"] = .bool(newValue) }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let values = (try? container.decode([String: RawJSONValue].self)) ?? [:]
        self.init(rawValues: values)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValues)
    }
}

public struct RecordSettings: Codable, Sendable, Equatable {
    /// All keys are the server's snake_case keys. Unknown keys remain here.
    public private(set) var rawValues: [String: RawJSONValue]

    public init(rawValues: [String: RawJSONValue] = [:]) {
        var values: [String: RawJSONValue] = [
            "is_enabled": .bool(true),
            "priority": .integer(3),
            "recording_folders": .array([]),
            "recording_start_margin": .null,
            "recording_end_margin": .null,
            "recording_mode": .string("SpecifiedService"),
            "caption_recording_mode": .string("Default"),
            "data_broadcasting_recording_mode": .string("Default"),
            "post_recording_mode": .string("Default"),
            "post_recording_bat_file_path": .null,
            "is_event_relay_follow_enabled": .bool(true),
            "is_exact_recording_enabled": .bool(false),
            "is_oneseg_separate_output_enabled": .bool(false),
            "is_sequential_recording_in_single_file_enabled": .bool(false),
            "forced_tuner_id": .null
        ]
        for (key, value) in rawValues { values[key] = value }
        self.rawValues = values
    }

    public var isEnabled: Bool {
        get { rawValues["is_enabled"]?.boolValue ?? true }
        set { rawValues["is_enabled"] = .bool(newValue) }
    }

    public var priority: Int {
        get { rawValues["priority"]?.intValue ?? 3 }
        set { rawValues["priority"] = .integer(newValue) }
    }

    public var recordingFolders: [RecordingFolder] {
        get {
            guard case .array(let values) = rawValues["recording_folders"] else { return [] }
            return values.compactMap {
                guard case .object(let value) = $0 else { return nil }
                return RecordingFolder(rawValues: value)
            }
        }
        set {
            rawValues["recording_folders"] = .array(newValue.map { .object($0.rawValues) })
        }
    }

    public var startMargin: Int? {
        get { rawValues["recording_start_margin"]?.nullableIntValue }
        set { rawValues["recording_start_margin"] = newValue.map(RawJSONValue.integer) ?? .null }
    }

    public var endMargin: Int? {
        get { rawValues["recording_end_margin"]?.nullableIntValue }
        set { rawValues["recording_end_margin"] = newValue.map(RawJSONValue.integer) ?? .null }
    }

    public var recordingMode: String {
        get { rawValues["recording_mode"]?.stringValue ?? "SpecifiedService" }
        set { rawValues["recording_mode"] = .string(newValue) }
    }

    public var captionRecordingMode: String {
        get { rawValues["caption_recording_mode"]?.stringValue ?? "Default" }
        set { rawValues["caption_recording_mode"] = .string(newValue) }
    }

    public var dataBroadcastingRecordingMode: String {
        get { rawValues["data_broadcasting_recording_mode"]?.stringValue ?? "Default" }
        set { rawValues["data_broadcasting_recording_mode"] = .string(newValue) }
    }

    public var postRecordingMode: String {
        get { rawValues["post_recording_mode"]?.stringValue ?? "Default" }
        set { rawValues["post_recording_mode"] = .string(newValue) }
    }

    public var postRecordingBatFilePath: String? {
        get { rawValues["post_recording_bat_file_path"]?.nullableStringValue }
        set { rawValues["post_recording_bat_file_path"] = newValue.map(RawJSONValue.string) ?? .null }
    }

    public var isEventRelayFollowEnabled: Bool {
        get { rawValues["is_event_relay_follow_enabled"]?.boolValue ?? true }
        set { rawValues["is_event_relay_follow_enabled"] = .bool(newValue) }
    }

    public var isExactRecordingEnabled: Bool {
        get { rawValues["is_exact_recording_enabled"]?.boolValue ?? false }
        set { rawValues["is_exact_recording_enabled"] = .bool(newValue) }
    }

    public var isOnesegSeparateOutputEnabled: Bool {
        get { rawValues["is_oneseg_separate_output_enabled"]?.boolValue ?? false }
        set { rawValues["is_oneseg_separate_output_enabled"] = .bool(newValue) }
    }

    public var isSequentialRecordingInSingleFileEnabled: Bool {
        get { rawValues["is_sequential_recording_in_single_file_enabled"]?.boolValue ?? false }
        set { rawValues["is_sequential_recording_in_single_file_enabled"] = .bool(newValue) }
    }

    public var forcedTunerID: Int? {
        get { rawValues["forced_tuner_id"]?.nullableIntValue }
        set { rawValues["forced_tuner_id"] = newValue.map(RawJSONValue.integer) ?? .null }
    }

    // Names used by the Android model are retained as aliases for UI code.
    public var recordingStartMargin: Int? {
        get { startMargin }
        set { startMargin = newValue }
    }

    public var recordingEndMargin: Int? {
        get { endMargin }
        set { endMargin = newValue }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValues: try container.decode([String: RawJSONValue].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValues)
    }
}

private extension RawJSONValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var nullableStringValue: String? {
        if case .null = self { return nil }
        return stringValue
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .integer(let value): return value
        case .number(let value) where value.isFinite && value.rounded() == value:
            return Int(exactly: value)
        default: return nil
        }
    }

    var nullableIntValue: Int? {
        if case .null = self { return nil }
        return intValue
    }
}

// MARK: - Reservation models

public struct Reservation: Decodable, Identifiable, Sendable, Equatable {
    public let id: Int
    public let channel: GuideChannel
    public let program: GuideProgram
    public let isRecordingInProgress: Bool
    public let recordingAvailability: String
    public let comment: String
    public let scheduledRecordingFileName: String
    public let estimatedRecordingFileSize: Int64
    public let recordSettings: RecordSettings

    public init(
        id: Int,
        channel: GuideChannel,
        program: GuideProgram,
        recordSettings: RecordSettings,
        isRecordingInProgress: Bool = false,
        recordingAvailability: String = "Pending",
        comment: String = "",
        scheduledRecordingFileName: String = "",
        estimatedRecordingFileSize: Int64 = 0
    ) {
        self.id = id
        self.channel = channel
        self.program = program
        self.isRecordingInProgress = isRecordingInProgress
        self.recordingAvailability = recordingAvailability
        self.comment = comment
        self.scheduledRecordingFileName = scheduledRecordingFileName
        self.estimatedRecordingFileSize = estimatedRecordingFileSize
        self.recordSettings = recordSettings
    }

    private enum CodingKeys: String, CodingKey {
        case id, channel, program, isRecordingInProgress, recordingAvailability, comment
        case scheduledRecordingFileName, estimatedRecordingFileSize, recordSettings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = (try? container.decodeIfPresent(Int.self, forKey: .id)) ?? 0
        guard decodedID > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Reservation id must be greater than zero"
            )
        }
        id = decodedID
        channel = (try? container.decodeIfPresent(GuideChannel.self, forKey: .channel)) ?? GuideChannel()
        let decodedProgram = (try? container.decodeIfPresent(GuideProgram.self, forKey: .program)) ?? GuideProgram()
        guard !decodedProgram.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .program,
                in: container,
                debugDescription: "Reservation program id must not be empty"
            )
        }
        program = decodedProgram
        // This flag gates destructive UI actions such as stopping a recording;
        // a missing or malformed value must fail closed instead of becoming
        // false and being treated as safe to delete.
        isRecordingInProgress = try container.decode(Bool.self, forKey: .isRecordingInProgress)
        recordingAvailability = (try? container.decodeIfPresent(String.self, forKey: .recordingAvailability)) ?? "Pending"
        comment = (try? container.decodeIfPresent(String.self, forKey: .comment)) ?? ""
        scheduledRecordingFileName = (try? container.decodeIfPresent(String.self, forKey: .scheduledRecordingFileName)) ?? ""
        estimatedRecordingFileSize = Int64((try? container.decodeIfPresent(Int.self, forKey: .estimatedRecordingFileSize)) ?? 0)
        recordSettings = try container.decode(RecordSettings.self, forKey: .recordSettings)
    }
}

public struct ReservationsResponse: Decodable, Sendable, Equatable {
    public let total: Int
    public let reservations: [Reservation]

    public init(total: Int = 0, reservations: [Reservation] = []) {
        self.total = total
        self.reservations = reservations
    }

    private enum CodingKeys: String, CodingKey { case total, reservations }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = try container.decode(Int.self, forKey: .total)
        reservations = try container.decode([Reservation].self, forKey: .reservations)
    }
}

public enum ReservationError: Error, LocalizedError, Equatable, Sendable {
    case invalidProgramID
    case invalidResponse
    case requestEncoding
    case emptyCreatedReservation
    case http(status: Int, detail: String?)

    public var statusCode: Int? {
        if case .http(let status, _) = self { return status }
        return nil
    }

    public var errorDescription: String? {
        switch self {
        case .invalidProgramID:
            return "録画予約する番組IDが空です。"
        case .invalidResponse:
            return "予約サーバーから不正な応答を受け取りました。"
        case .requestEncoding:
            return "録画予約の設定を送信形式に変換できませんでした。"
        case .emptyCreatedReservation:
            return "予約は追加されましたが、追加結果を取得できませんでした。予約一覧を再読み込みしてください。"
        case .http(let status, let detail):
            let message: String
            switch status {
            case 401, 403: message = "録画予約を操作する権限がありません。"
            case 404: message = "指定した予約または番組が見つかりません。"
            case 409: message = "録画予約の状態が競合しています。"
            case 422: message = "録画予約の内容を確認してください。"
            case 500...599: message = "録画サーバー側で予約処理に失敗しました。"
            default: message = "予約サーバーがHTTP \(status)を返しました。"
            }
            return detail.map { "\(message) \($0)" } ?? message
        }
    }
}

// MARK: - Client operations

private struct ReservationAddRequest: Encodable, Sendable {
    let programID: String
    let recordSettings: RecordSettings

    private enum CodingKeys: String, CodingKey {
        case programID = "program_id"
        case recordSettings = "record_settings"
    }
}

private struct ReservationUpdateRequest: Encodable, Sendable {
    let recordSettings: RecordSettings

    private enum CodingKeys: String, CodingKey { case recordSettings = "record_settings" }
}

public extension RingonomiClient {
    func reservations(using session: URLSession = .shared) async throws -> ReservationsResponse {
        try await request(
            path: ["api", "recording", "reservations"],
            method: "GET",
            body: nil,
            using: session,
            decode: ReservationsResponse.self
        )
    }

    func reservation(id: Int, using session: URLSession = .shared) async throws -> Reservation {
        try await request(
            path: ["api", "recording", "reservations", String(id)],
            method: "GET",
            body: nil,
            using: session,
            decode: Reservation.self
        )
    }

    func addReservation(
        programID: String,
        settings: RecordSettings = RecordSettings(),
        using session: URLSession = .shared
    ) async throws -> Reservation {
        guard !programID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReservationError.invalidProgramID
        }
        let request = ReservationAddRequest(programID: programID, recordSettings: settings)
        let body = try encodeRequest(request)
        let response: (data: Data, status: Int) = try await requestRaw(
            path: ["api", "recording", "reservations"],
            method: "POST",
            body: body,
            using: session
        )
        if !Self.isEmptyResponseBody(response.data) {
            return try decodeResponse(Reservation.self, from: response.data)
        }

        // The current OpenAPI declares an empty 201 body, but FastAPI may
        // serialize that body as whitespace or JSON null. A follow-up GET is
        // retrieval, not a retry, and prevents a POST timeout from being sent
        // again by this client.
        let list = try await reservations(using: session)
        guard let created = list.reservations.first(where: { $0.program.id == programID }) else {
            throw ReservationError.emptyCreatedReservation
        }
        return created
    }

    func updateReservation(
        id: Int,
        settings: RecordSettings,
        using session: URLSession = .shared
    ) async throws -> Reservation {
        let updateRequest = ReservationUpdateRequest(recordSettings: settings)
        let body = try encodeRequest(updateRequest)
        let response: (data: Data, status: Int) = try await requestRaw(
            path: ["api", "recording", "reservations", String(id)],
            method: "PUT",
            body: body,
            using: session
        )
        if Self.isEmptyResponseBody(response.data) {
            // The documented response contains the updated reservation. If a
            // compatible server returns an empty 2xx body, retrieve the state
            // once instead of reporting a successful update with stale UI data.
            return try await reservation(id: id, using: session)
        }
        return try decodeResponse(Reservation.self, from: response.data)
    }

    func deleteReservation(id: Int, using session: URLSession = .shared) async throws {
        _ = try await requestRaw(
            path: ["api", "recording", "reservations", String(id)],
            method: "DELETE",
            body: nil,
            using: session
        )
    }
}

extension RingonomiClient {
    func request<T: Decodable & Sendable>(
        path: [String],
        method: String,
        body: Data?,
        using session: URLSession,
        decode type: T.Type
    ) async throws -> T {
        let response = try await requestRaw(path: path, method: method, body: body, using: session)
        return try decodeResponse(type, from: response.data)
    }

    func requestRaw(
        path: [String],
        method: String,
        body: Data?,
        using session: URLSession
    ) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = method
        request.timeoutInterval = 20
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await backendData(for: request, using: session)
        } catch let error as ConnectionError {
            // Keep the pre-transport invalid-response contract. HTTP status
            // errors intentionally remain available as URLResponse values so
            // this API can preserve its server-detail behavior for 4xx/409.
            if case .http(0) = error {
                throw ReservationError.invalidResponse
            }
            throw error
        }
        guard let response = response as? HTTPURLResponse else { throw ReservationError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let detail: String?
            switch response.statusCode {
            case 401, 403:
                // Do not echo an arbitrary server response into a user-facing
                // error. Keep a stable client-side HTTP description instead.
                detail = ConnectionError.http(response.statusCode).errorDescription
            default:
                detail = Self.serverDetail(from: data)
            }
            throw ReservationError.http(status: response.statusCode, detail: detail)
        }
        return (data, response.statusCode)
    }

    func encodeRequest<T: Encodable>(_ value: T) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(value)
        } catch {
            throw ReservationError.requestEncoding
        }
    }

    func decodeResponse<T: Decodable & Sendable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(type, from: data)
        } catch {
            throw ReservationError.invalidResponse
        }
    }

    static func isEmptyResponseBody(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        guard let value = try? JSONDecoder().decode(RawJSONValue.self, from: data) else {
            return false
        }
        if case .null = value { return true }
        return false
    }

    static func serverDetail(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let value = try? JSONDecoder().decode(RawJSONValue.self, from: data),
           case .object(let object) = value,
           let detail = object["detail"] {
            return detailText(detail)
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    static func detailText(_ value: RawJSONValue) -> String? {
        switch value {
        case .null: return nil
        case .string(let value): return value
        case .bool(let value): return String(value)
        case .integer(let value): return String(value)
        case .number(let value): return String(value)
        case .array(let values):
            let parts = values.compactMap(detailText)
            return parts.isEmpty ? nil : parts.joined(separator: " / ")
        case .object(let values):
            let parts: [String] = values.sorted { $0.key < $1.key }.compactMap { entry in
                let key = entry.key
                let value = entry.value
                guard let text = detailText(value) else { return nil }
                return "\(key): \(text)"
            }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
    }
}
