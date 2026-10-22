import Foundation

struct HTTPMediaRelayRequest: Sendable {
    static let maximumHeaderBytes = 32 * 1024
    let url: URL
    let isHead: Bool
    let range: HTTPMediaByteRange?

    init(header: Data, origin: URL) throws {
        guard header.count <= Self.maximumHeaderBytes,
              let text = String(data: header, encoding: .ascii), text.hasSuffix("\r\n\r\n") else {
            throw HLSRelayError.invalidRoute
        }
        let lines = text.components(separatedBy: "\r\n")
        guard lines.count >= 4, !lines.dropLast(2).contains(""),
              let first = lines.first else { throw HLSRelayError.invalidRoute }
        let request = first.split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[0] == "GET" || request[0] == "HEAD",
              request[2] == "HTTP/1.1", request[1].hasPrefix("/"), !request[1].hasPrefix("//"),
              let url = URL(string: String(request[1]), relativeTo: origin)?.absoluteURL else {
            throw HLSRelayError.invalidRoute
        }
        var fields: [String: String] = [:]
        for line in lines.dropFirst().dropLast(2) {
            guard let colon = line.firstIndex(of: ":") else { throw HLSRelayError.invalidRoute }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy({ (0x61...0x7A).contains($0) ||
                (0x30...0x39).contains($0) || $0 == 0x2D }), fields[name] == nil else {
                throw HLSRelayError.invalidRoute
            }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard value.utf8.allSatisfy({ (0x20...0x7E).contains($0) }) else { throw HLSRelayError.invalidRoute }
            fields[name] = value
        }
        guard let port = origin.port, fields["host"] == "127.0.0.1:\(port)",
              fields["transfer-encoding"] == nil,
              fields["content-length"] == nil || fields["content-length"] == "0" else {
            throw HLSRelayError.invalidRoute
        }
        self.url = url
        isHead = request[0] == "HEAD"
        range = isHead ? nil : try fields["range"].map(HTTPMediaByteRange.init)
    }
}

struct HTTPMediaByteRange: Sendable, Equatable {
    let start: Int64?
    let end: Int64?

    init(_ header: String) throws {
        guard header.hasPrefix("bytes="), header.utf8.count <= 64 else { throw HLSRelayError.invalidRoute }
        let fields = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 2 else { throw HLSRelayError.invalidRoute }
        func number(_ value: Substring) throws -> Int64? {
            if value.isEmpty { return nil }
            guard value.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let result = Int64(value) else {
                throw HLSRelayError.invalidRoute
            }
            return result
        }
        start = try number(fields[0]); end = try number(fields[1])
        guard start != nil || (end ?? 0) > 0,
              start == nil || end == nil || end! >= start! else { throw HLSRelayError.invalidRoute }
    }

    var headerValue: String { "bytes=\(start.map(String.init) ?? "")-\(end.map(String.init) ?? "")" }

    func indices(in count: Int) throws -> Range<Int> {
        guard count > 0 else { throw HLSRelayError.invalidRoute }
        let lower: Int64
        let upper: Int64
        if let start {
            lower = start; upper = min(end ?? Int64(count - 1), Int64(count - 1))
        } else {
            lower = max(0, Int64(count) - (end ?? 0)); upper = Int64(count - 1)
        }
        guard lower <= upper, lower < Int64(count) else { throw HLSRelayError.invalidRoute }
        return Int(lower)..<(Int(upper) + 1)
    }
}
