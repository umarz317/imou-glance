import Foundation

struct NativeMediaFramer {
    enum Format { case privateRTP, privateXAV }
    private static let limit = 5 * 1024 * 1024
    private let format: Format
    private var buffer = Data()
    private struct Source: Hashable {
        let channel: UInt8
        let ssrc: UInt32
    }

    private struct Assembly {
        private var sequence: UInt16?
        private var buffer = Data()
        private var length: Int?
        private static let magic = Data([0x44, 0x48, 0x41, 0x56])

        mutating func append(_ payload: Data, sequence number: UInt16) -> [Data] {
            if let sequence {
                let distance = number &- sequence
                // Ignore duplicate and stale packets, including after sequence wrap.
                guard distance != 0, distance < 0x8000 else { return [] }
                if distance != 1 {
                    buffer.removeAll(keepingCapacity: true)
                    length = nil
                }
            }
            sequence = number
            buffer.append(payload)
            var frames: [Data] = []
            while !buffer.isEmpty {
                if length == nil {
                    guard let boundary = buffer.range(of: Self.magic) else {
                        // Retain only a possible fragmented DHAV magic prefix.
                        let suffix = (1...3).reversed().first {
                            buffer.count >= $0 && buffer.suffix($0).elementsEqual(Self.magic.prefix($0))
                        } ?? 0
                        buffer = Data(buffer.suffix(suffix))
                        break
                    }
                    buffer.removeSubrange(buffer.startIndex..<boundary.lowerBound)
                    guard buffer.count >= 24 else { break }
                    let header = [UInt8](buffer.prefix(24))
                    let candidate = Int(header[12]) | Int(header[13]) << 8 |
                                    Int(header[14]) << 16 | Int(header[15]) << 24
                    let checksum = header.prefix(23).reduce(UInt8(0)) { $0 &+ $1 }
                    guard candidate >= 32 + Int(header[22]), candidate <= NativeMediaFramer.limit,
                          header[23] == checksum else {
                        // A lost fragment may contain an incidental magic string.
                        // Only a complete valid header establishes a new boundary.
                        buffer.removeFirst()
                        continue
                    }
                    length = candidate
                }
                guard let length, buffer.count >= length else { break }
                frames.append(Data(buffer.prefix(length)))
                buffer.removeFirst(length)
                self.length = nil
            }
            return frames
        }
    }

    // Each independent interleaved source retains at most one incomplete 5 MiB
    // frame, bounding retained assembly data to 40 MiB across the eight sources.
    private var sources: [Source: Assembly] = [:]
    private var preambleRemaining: Int

    init(format: Format = .privateRTP, preambleLength: Int = 0) {
        self.format = format
        self.preambleRemaining = preambleLength
    }

    static func preambleLength(from field: String?) throws -> Int {
        guard let field else { return 0 }
        guard !field.isEmpty, field.utf8.allSatisfy({ (48...57).contains($0) }),
              let length = Int(field), length <= 32 * 1024 else {
            throw ImouError.message("Camera relay returned an invalid private header length.")
        }
        return length
    }

    mutating func append(_ data: Data) throws -> [Data] {
        guard buffer.count + data.count <= 16 * 1024 * 1024 else { throw invalid() }
        buffer.append(data)
        // Native HTTP responses carry an SDP body counted by Private-Length,
        // followed immediately by interleaved media (not another HTTP response).
        if preambleRemaining > 0 {
            let count = min(preambleRemaining, buffer.count)
            buffer.removeFirst(count)
            preambleRemaining -= count
            guard preambleRemaining == 0 else { return [] }
        }
        var packets: [Data] = []
        let width = format == .privateRTP ? 4 : 6
        while buffer.count >= width {
            let start = buffer.startIndex
            guard buffer[start] == 0x24 else { throw invalid() }
            let length: Int
            if width == 4 {
                length = Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
            } else {
                length = Int(buffer[start + 2]) << 24 | Int(buffer[start + 3]) << 16 |
                         Int(buffer[start + 4]) << 8 | Int(buffer[start + 5])
            }
            guard length <= Self.limit else { throw invalid() }
            guard buffer.count >= width + length else { break }
            let channel = buffer[start + 1]
            let body = buffer.subdata(in: (start + width)..<(start + width + length))
            buffer.removeSubrange(start..<(start + width + length))
            if body.isEmpty { continue }
            if format == .privateXAV { packets.append(body) }
            else { packets += try privatePayload(body, channel: channel) }
        }
        return packets
    }

    private mutating func privatePayload(_ packet: Data, channel: UInt8) throws -> [Data] {
        let bytes = [UInt8](packet)
        guard bytes.count >= 2, bytes[0] & 0xc0 == 0x80 else { throw invalid() }
        if (192...223).contains(bytes[1]) { return [] } // RTCP control packets.
        guard bytes.count >= 12 else { throw invalid() }
        var offset = 12 + Int(bytes[0] & 0x0f) * 4
        guard offset <= bytes.count else { throw invalid() }
        if bytes[0] & 0x10 != 0 {
            guard offset + 4 <= bytes.count else { throw invalid() }
            let words = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4 + words * 4
            guard offset <= bytes.count else { throw invalid() }
        }
        var end = bytes.count
        if bytes[0] & 0x20 != 0 {
            let padding = Int(bytes[end - 1])
            guard padding > 0, padding <= end - offset else { throw invalid() }
            end -= padding
        }
        let source = UInt32(bytes[8]) << 24 | UInt32(bytes[9]) << 16 | UInt32(bytes[10]) << 8 | UInt32(bytes[11])
        let number = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        let key = Source(channel: channel, ssrc: source)
        guard sources[key] != nil || sources.count < 8 else { throw invalid() }
        // Native private encodings permit PT changes. Audio and video may both
        // carry DHAV, while each interleaved source has its own sequence space.
        return sources[key, default: Assembly()].append(Data(bytes[offset..<end]), sequence: number)
    }

    private func invalid() -> ImouError {
        .message("Camera returned an unsupported private media stream.")
    }
}
