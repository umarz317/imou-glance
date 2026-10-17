import Foundation

struct NativeHTTPResponseParser {
    enum Event: Equatable {
        case response(status: Int, contentType: String, privateLength: String? = nil)
        case body(Data)
        case end
    }

    enum ParseError: Error {
        case malformedResponse, responseTooLarge, unsupportedEncoding, truncatedResponse
    }

    private enum State {
        case headers, fixed(Int), chunkSize, chunkData(Int), chunkEnd, trailers, closeDelimited, ended
    }

    private var state = State.headers
    private var buffer = Data()
    private var trailerBytes = 0
    private static let headerLimit = 64 * 1024
    private static let chunkLineLimit = 4096

    mutating func append(_ data: Data) throws -> [Event] {
        buffer.append(data)
        var events: [Event] = []
        while true {
            switch state {
            case .headers:
                let marker = Data([13, 10, 13, 10])
                guard let boundary = buffer.range(of: marker) else {
                    guard buffer.count <= Self.headerLimit else { throw ParseError.responseTooLarge }
                    try Self.validateLineBreaks(buffer)
                    return events
                }
                let length = buffer.distance(from: buffer.startIndex, to: boundary.upperBound)
                guard length <= Self.headerLimit else { throw ParseError.responseTooLarge }
                let header = take(length)
                try Self.validateLineBreaks(header)
                let lines = String(decoding: header.dropLast(4), as: UTF8.self).components(separatedBy: "\r\n")
                guard let first = lines.first else { throw ParseError.malformedResponse }
                let statusLine = Array(first.utf8)
                guard statusLine.count >= 12,
                      ["HTTP/1.0", "HTTP/1.1"].contains(String(decoding: statusLine.prefix(8), as: UTF8.self)),
                      statusLine[8] == 32, statusLine[9...11].allSatisfy({ (48...57).contains($0) }),
                      statusLine.count == 12 || statusLine[12] == 32,
                      statusLine.dropFirst(12).allSatisfy(Self.isFieldValueByte),
                      let status = Int(String(decoding: statusLine[9...11], as: UTF8.self)),
                      (100...599).contains(status), status != 101 else { throw ParseError.malformedResponse }
                var fields: [String: String] = [:]
                for line in lines.dropFirst() {
                    let (name, value) = try Self.field(line)
                    if ["content-length", "transfer-encoding", "content-encoding", "content-type", "private-length"].contains(name) {
                        guard fields.updateValue(value, forKey: name) == nil else { throw ParseError.malformedResponse }
                    }
                }
                let transfer = fields["transfer-encoding"]?.lowercased()
                let lengthText = fields["content-length"]
                guard transfer == nil || lengthText == nil else { throw ParseError.malformedResponse }
                guard transfer == nil || transfer == "chunked",
                      fields["content-encoding"].map({ $0.lowercased() == "identity" }) ?? true else {
                    throw ParseError.unsupportedEncoding
                }
                var contentLength: Int?
                if let lengthText {
                    guard !lengthText.isEmpty, lengthText.utf8.allSatisfy({ (48...57).contains($0) }),
                          let parsed = Int(lengthText) else { throw ParseError.malformedResponse }
                    contentLength = parsed
                }
                events.append(.response(status: status, contentType: fields["content-type"] ?? "",
                                        privateLength: fields["private-length"]))
                if (100...199).contains(status) {
                    guard transfer == nil, contentLength == nil else { throw ParseError.malformedResponse }
                    state = .headers
                } else if status == 204 || status == 304 {
                    guard transfer == nil, status != 204 || contentLength == nil else { throw ParseError.malformedResponse }
                    state = .ended
                    events.append(.end)
                } else if transfer == "chunked" {
                    state = .chunkSize
                } else if let contentLength {
                    state = .fixed(contentLength)
                } else {
                    state = .closeDelimited
                }
            case .fixed(let remaining):
                if remaining == 0 {
                    state = .ended
                    events.append(.end)
                } else {
                    guard !buffer.isEmpty else { return events }
                    let count = min(remaining, buffer.count)
                    events.append(.body(take(count)))
                    state = .fixed(remaining - count)
                }
            case .chunkSize:
                guard let line = try line(limit: Self.chunkLineLimit) else { return events }
                let size = try Self.chunkSize(line)
                state = size == 0 ? .trailers : .chunkData(size)
            case .chunkData(let remaining):
                guard !buffer.isEmpty else { return events }
                let count = min(remaining, buffer.count)
                events.append(.body(take(count)))
                state = count == remaining ? .chunkEnd : .chunkData(remaining - count)
            case .chunkEnd:
                guard !buffer.isEmpty else { return events }
                guard buffer.first == 13 else { throw ParseError.malformedResponse }
                guard buffer.count >= 2 else { return events }
                guard take(2) == Data([13, 10]) else { throw ParseError.malformedResponse }
                state = .chunkSize
            case .trailers:
                guard let line = try line(limit: Self.headerLimit - trailerBytes) else { return events }
                trailerBytes += line.count + 2
                if line.isEmpty {
                    state = .ended
                    events.append(.end)
                } else {
                    let (name, _) = try Self.field(String(decoding: line, as: UTF8.self))
                    guard !["content-length", "transfer-encoding", "content-encoding", "content-type"].contains(name) else {
                        throw ParseError.malformedResponse
                    }
                }
            case .closeDelimited:
                if !buffer.isEmpty { events.append(.body(take(buffer.count))) }
                return events
            case .ended:
                guard buffer.isEmpty else { throw ParseError.malformedResponse }
                return events
            }
        }
    }

    // A clean network EOF terminates only a close-delimited response; other unfinished states are truncation.
    mutating func finish() throws -> [Event] {
        switch state {
        case .closeDelimited:
            state = .ended
            return [.end]
        case .ended:
            return []
        default:
            throw ParseError.truncatedResponse
        }
    }

    private mutating func take(_ count: Int) -> Data {
        let data = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return data
    }

    private mutating func line(limit: Int) throws -> Data? {
        guard let boundary = buffer.range(of: Data([13, 10])) else {
            guard buffer.count < limit else { throw ParseError.responseTooLarge }
            try Self.validateLineBreaks(buffer)
            return nil
        }
        let length = buffer.distance(from: buffer.startIndex, to: boundary.upperBound)
        guard length <= limit else { throw ParseError.responseTooLarge }
        let result = take(length)
        try Self.validateLineBreaks(result)
        return Data(result.dropLast(2))
    }

    private static func validateLineBreaks(_ data: Data) throws {
        let bytes = Array(data)
        for index in bytes.indices {
            if bytes[index] == 10 && (index == 0 || bytes[index - 1] != 13) { throw ParseError.malformedResponse }
            if bytes[index] == 13 && index + 1 < bytes.count && bytes[index + 1] != 10 { throw ParseError.malformedResponse }
        }
    }

    private static func field(_ line: String) throws -> (String, String) {
        guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
              line[..<colon].utf8.allSatisfy(isToken),
              line[line.index(after: colon)...].utf8.allSatisfy(isFieldValueByte) else { throw ParseError.malformedResponse }
        return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t")))
    }

    private static func isFieldValueByte(_ byte: UInt8) -> Bool { byte == 9 || byte >= 32 && byte != 127 }

    private static func isToken(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) ||
        Array("!#$%&'*+-.^_`|~".utf8).contains(byte)
    }

    private static func chunkSize(_ line: Data) throws -> Int {
        let bytes = Array(line)
        var index = 0
        var size = 0
        while index < bytes.count {
            let byte = bytes[index]
            let digit: Int
            switch byte {
            case 48...57: digit = Int(byte - 48)
            case 65...70: digit = Int(byte - 65 + 10)
            case 97...102: digit = Int(byte - 97 + 10)
            default: digit = -1
            }
            if digit < 0 { break }
            guard size <= (Int.max - digit) / 16 else { throw ParseError.malformedResponse }
            size = size * 16 + digit
            index += 1
        }
        guard index > 0 else { throw ParseError.malformedResponse }
        func skipWhitespace() { while index < bytes.count && [9, 32].contains(bytes[index]) { index += 1 } }
        while index < bytes.count {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 59 else { throw ParseError.malformedResponse }
            index += 1
            skipWhitespace()
            let start = index
            while index < bytes.count && isToken(bytes[index]) { index += 1 }
            guard index > start else { throw ParseError.malformedResponse }
            skipWhitespace()
            if index < bytes.count && bytes[index] == 61 {
                index += 1
                skipWhitespace()
                guard index < bytes.count else { throw ParseError.malformedResponse }
                if bytes[index] == 34 {
                    index += 1
                    var closed = false
                    while index < bytes.count {
                        let byte = bytes[index]
                        index += 1
                        if byte == 34 { closed = true; break }
                        if byte == 92 {
                            guard index < bytes.count, isFieldValueByte(bytes[index]) else { throw ParseError.malformedResponse }
                            index += 1
                        } else if !isFieldValueByte(byte) { throw ParseError.malformedResponse }
                    }
                    guard closed else { throw ParseError.malformedResponse }
                } else {
                    let start = index
                    while index < bytes.count && isToken(bytes[index]) { index += 1 }
                    guard index > start else { throw ParseError.malformedResponse }
                }
            }
        }
        return size
    }
}
