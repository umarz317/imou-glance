import XCTest
@testable import ImouMac

final class NativeMediaFramerTests: XCTestCase {
    private func frame(fill: UInt8 = 0x55) -> Data {
        var bytes = [UInt8](repeating: fill, count: 64)
        bytes.replaceSubrange(0..<24, with: [UInt8](repeating: 0, count: 24))
        bytes.replaceSubrange(0..<4, with: [0x44, 0x48, 0x41, 0x56])
        bytes[12] = 64
        bytes[23] = bytes.prefix(23).reduce(UInt8(0)) { $0 &+ $1 }
        bytes.replaceSubrange(56..<64, with: [0x64, 0x68, 0x61, 0x76, 64, 0, 0, 0])
        return Data(bytes)
    }

    private func rtp(_ payload: Data, sequence: UInt16, type: UInt8 = 98, source: UInt32 = 1,
                     channel: UInt8 = 0, metadata: Bool = false) -> Data {
        var bytes: [UInt8] = [metadata ? 0xb1 : 0x80, type, UInt8(sequence >> 8), UInt8(sequence & 255), 0, 0, 0, 0,
                             UInt8(source >> 24), UInt8((source >> 16) & 255), UInt8((source >> 8) & 255), UInt8(source & 255)]
        if metadata { bytes += [0, 0, 0, 2, 0xab, 0xac, 0, 1, 1, 2, 3, 4] }
        bytes += payload
        if metadata { bytes += [0, 0, 3] }
        return Data([0x24, channel, UInt8(bytes.count >> 8), UInt8(bytes.count & 255)] + bytes)
    }

    func testRTPHeadersExtensionsPaddingAndFragmentedPrivateHeader() throws {
        let privateFrame = frame()
        let bytes = rtp(privateFrame.prefix(16), sequence: 65535, metadata: true) +
                    rtp(privateFrame.dropFirst(16), sequence: 0, metadata: true) +
                    Data([0x24, 1, 0, 8, 0x80, 201, 0, 1, 0, 0, 0, 1]) +
                    rtp(Data([1, 2, 3]), sequence: 45, type: 8, source: 2) +
                    rtp(privateFrame, sequence: 1)
        for width in [1, 3, 7, bytes.count] {
            var framer = NativeMediaFramer()
            var result: [Data] = []
            for offset in stride(from: 0, to: bytes.count, by: width) {
                result += try framer.append(bytes.subdata(in: offset..<min(bytes.count, offset + width)))
            }
            XCTAssertEqual(result, [privateFrame, privateFrame])
        }
    }

    func testDamagedHeaderCannotEscapeAndNextValidBoundaryRecovers() throws {
        var broken = frame()
        broken[23] ^= 1
        var framer = NativeMediaFramer()
        XCTAssertTrue(try framer.append(rtp(broken, sequence: 1)).isEmpty)
        XCTAssertEqual(try framer.append(rtp(frame(), sequence: 2)), [frame()])

        for length in [31, 5 * 1024 * 1024 + 1] {
            var oversized = frame()
            for index in 0..<4 { oversized[12 + index] = UInt8((length >> (index * 8)) & 255) }
            oversized[23] = oversized.prefix(23).reduce(UInt8(0)) { $0 &+ $1 }
            var bounded = NativeMediaFramer()
            XCTAssertEqual(try bounded.append(rtp(oversized + frame(), sequence: 1)), [frame()])
        }
    }

    func testAudioFirstAndInterleavedSourcesHaveIndependentSequenceSpaces() throws {
        let audio = frame(fill: 0x11)
        let video = frame(fill: 0x22)
        // Cover both ways sources can differ: channel with equal SSRC, and SSRC
        // with equal channel. PT alone never selects the first track permanently.
        for (audioChannel, audioSource) in [(UInt8(2), UInt32(1)), (UInt8(0), UInt32(2))] {
            var framer = NativeMediaFramer()
            let packets = rtp(audio, sequence: 13991, type: 97, source: audioSource, channel: audioChannel) +
                rtp(video.prefix(30), sequence: 16979) +
                rtp(audio.prefix(20), sequence: 13992, type: 97, source: audioSource, channel: audioChannel) +
                rtp(video.dropFirst(30), sequence: 16980) +
                rtp(audio.dropFirst(20), sequence: 13993, type: 97, source: audioSource, channel: audioChannel)
            XCTAssertEqual(try framer.append(packets), [audio, video, audio])
        }
    }

    func testPrivatePayloadTypeChangesDoNotInterruptFrameAssembly() throws {
        let media = frame()
        var framer = NativeMediaFramer()
        XCTAssertTrue(try framer.append(rtp(media.prefix(13), sequence: 1, type: 97)).isEmpty)
        XCTAssertEqual(try framer.append(rtp(media.dropFirst(13), sequence: 2, type: 98)), [media])
    }

    func testSequenceGapDiscardsPartialFrameAndRecoversAtNextValidBoundary() throws {
        let incomplete = frame(fill: 0x11)
        let complete = frame(fill: 0x22)
        for prefix in [2, 16, 40] {
            var framer = NativeMediaFramer()
            XCTAssertTrue(try framer.append(rtp(incomplete.prefix(prefix), sequence: 19102)).isEmpty)
            // A genuine gap arrives in the middle of the previous frame. The
            // next header itself straddles packets, after leftover frame bytes.
            XCTAssertTrue(try framer.append(rtp(incomplete.dropFirst(40) + complete.prefix(2), sequence: 19239)).isEmpty)
            XCTAssertEqual(try framer.append(rtp(complete.dropFirst(2), sequence: 19240)), [complete])
            XCTAssertEqual(try framer.append(rtp(complete, sequence: 19242)), [complete])
        }
    }

    func testDuplicatesAndStalePacketsNeverRepeatOrCorruptAFrame() throws {
        let media = frame()
        var framer = NativeMediaFramer()
        let first = rtp(media.prefix(16), sequence: 65535)
        let last = rtp(media.dropFirst(16), sequence: 0)
        XCTAssertTrue(try framer.append(first + first).isEmpty)
        XCTAssertEqual(try framer.append(last + first + last), [media])
        XCTAssertEqual(try framer.append(rtp(media, sequence: 1)), [media])
    }

    func testFragmentedMagicAndMultipleFramesPerPayload() throws {
        let first = frame(fill: 0x11)
        let second = frame(fill: 0x22)
        for split in 1..<24 {
            var framer = NativeMediaFramer()
            XCTAssertTrue(try framer.append(rtp(first.prefix(split), sequence: 1)).isEmpty)
            XCTAssertEqual(try framer.append(rtp(first.dropFirst(split) + second + first, sequence: 2)),
                           [first, second, first])
        }
    }

    func testSourceCountAndRTPMetadataAreBounded() throws {
        var framer = NativeMediaFramer()
        for source in UInt32(1)...8 {
            XCTAssertEqual(try framer.append(rtp(frame(), sequence: 1, source: source)), [frame()])
        }
        XCTAssertThrowsError(try framer.append(rtp(frame(), sequence: 1, source: 9)))
        var invalidRTP = NativeMediaFramer()
        XCTAssertThrowsError(try invalidRTP.append(Data([0x24, 0, 0, 2, 0x80, 98])))
    }

    func testPrivateXAVUsesSixByteFramingAndRejectsOversizedInput() throws {
        let packet = Data([0x24, 0, 0, 0, 0, 64]) + frame()
        var framer = NativeMediaFramer(format: .privateXAV)
        XCTAssertTrue(try framer.append(packet.prefix(5)).isEmpty)
        XCTAssertEqual(try framer.append(packet.dropFirst(5)), [frame()])
        XCTAssertThrowsError(try framer.append(Data([0x24, 0, 0xff, 0xff, 0xff, 0xff])))
        var invalid = NativeMediaFramer()
        XCTAssertThrowsError(try invalid.append(Data([0, 0, 0, 0])))
    }

    func testHTTPPrivateLengthSeparatesSDPFromMediaAcrossEverySplit() throws {
        // Synthetic SDP deliberately contains '$'; the byte count, not a marker scan,
        // must identify the first media packet.
        let sdp = Data("v=0\r\ns=synthetic $ session\r\nt=0 0\r\n".utf8)
        for format in [NativeMediaFramer.Format.privateRTP, .privateXAV] {
            let media = format == .privateRTP ? rtp(frame(), sequence: 1) :
                Data([0x24, 0, 0, 0, 0, 64]) + frame()
            let type = format == .privateRTP ? "video/e-rtpxav" : "video/e-xav"
            let bytes = Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nPrivate-Type: application/sdp\r\nPrivate-Length: \(sdp.count)\r\n\r\n".utf8) + sdp + media
            for split in 0...bytes.count {
                var http = NativeHTTPResponseParser()
                var framer = NativeMediaFramer()
                var result: [Data] = []
                for chunk in [Data(bytes.prefix(split)), Data(bytes.dropFirst(split))] {
                    for event in try http.append(chunk) {
                        switch event {
                        case .response(_, _, let length):
                            framer = NativeMediaFramer(format: format,
                                preambleLength: try NativeMediaFramer.preambleLength(from: length))
                        case .body(let data): result += try framer.append(data)
                        case .end: XCTFail("Private-Length must not terminate the HTTP stream")
                        }
                    }
                }
                XCTAssertEqual(result, [frame()])
            }
        }
    }

    func testPrivatePreambleLengthIsBoundedAndNotGuessed() throws {
        XCTAssertEqual(try NativeMediaFramer.preambleLength(from: nil), 0)
        XCTAssertEqual(try NativeMediaFramer.preambleLength(from: "583"), 583)
        for invalid in ["", "-1", "+1", "1x", "32769", String(repeating: "9", count: 40)] {
            XCTAssertThrowsError(try NativeMediaFramer.preambleLength(from: invalid))
        }
        var framer = NativeMediaFramer(preambleLength: 583)
        XCTAssertTrue(try framer.append(Data(repeating: 0x24, count: 582)).isEmpty)
        XCTAssertEqual(try framer.append(Data([0]) + rtp(frame(), sequence: 1)), [frame()])
        var http = NativeHTTPResponseParser()
        XCTAssertThrowsError(try http.append(Data("HTTP/1.1 200 OK\r\nPrivate-Length: 2\r\nPrivate-Length: 3\r\n\r\n".utf8)))
    }
}
