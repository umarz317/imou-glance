import XCTest
@testable import ImouMac

final class NativeHTTPResponseParserTests: XCTestCase {
    private func collect(_ wire: Data, width: Int) throws -> ([NativeHTTPResponseParser.Event], Data) {
        var parser = NativeHTTPResponseParser()
        var events: [NativeHTTPResponseParser.Event] = []
        for offset in stride(from: 0, to: wire.count, by: width) {
            events += try parser.append(wire.subdata(in: offset..<min(offset + width, wire.count)))
        }
        events += try parser.finish()
        let body = events.reduce(into: Data()) { result, event in
            if case .body(let data) = event { result.append(data) }
        }
        return (events, body)
    }

    func testFixedBodyAcrossEverySmallFragmentSize() throws {
        let body = Data([0, 13, 10, 0xff, 0x24, 65, 66])
        let wire = Data("HTTP/1.1 200 OK\r\nContent-Type: application/x-rtpxav\r\nContent-Length: 7\r\n\r\n".utf8) + body
        for width in 1...wire.count {
            let (events, actual) = try collect(wire, width: width)
            XCTAssertEqual(events.first, .response(status: 200, contentType: "application/x-rtpxav"))
            XCTAssertEqual(events.last, .end)
            XCTAssertEqual(events.filter { $0 == .end }.count, 1)
            XCTAssertEqual(actual, body)
        }
    }

    func testChunkedBodyExtensionsAndTrailersAcrossFragments() throws {
        let wire = Data(("HTTP/1.1 200 OK\r\nTransfer-Encoding: Chunked\r\nContent-Type: application/x-xav\r\n\r\n" +
            "3;name=token\r\nabc\r\n4; quote=\"a\\\"b\"\r\ndefg\r\n0\r\nX-Checksum: ignored\r\n\r\n").utf8)
        for width in 1...wire.count {
            let (events, body) = try collect(wire, width: width)
            XCTAssertEqual(events.first, .response(status: 200, contentType: "application/x-xav"))
            XCTAssertEqual(body, Data("abcdefg".utf8))
            XCTAssertEqual(events.last, .end)
        }
    }

    func testChunkDataIsDeliveredBeforeWholeChunkArrives() throws {
        var parser = NativeHTTPResponseParser()
        XCTAssertEqual(try parser.append(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n100000\r\nab".utf8)),
                       [.response(status: 200, contentType: ""), .body(Data("ab".utf8))])
        XCTAssertEqual(try parser.append(Data("cd".utf8)), [.body(Data("cd".utf8))])
        XCTAssertThrowsError(try parser.finish())
    }

    func testCloseDelimitedAndNoBodyResponses() throws {
        let (events, body) = try collect(Data("HTTP/1.0 200 OK\r\n\r\nbytes".utf8), width: 1)
        XCTAssertEqual(body, Data("bytes".utf8))
        XCTAssertEqual(events.last, .end)
        for header in ["HTTP/1.1 204 No Content\r\n\r\n", "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"] {
            var parser = NativeHTTPResponseParser()
            XCTAssertEqual(try parser.append(Data(header.utf8)).last, .end)
            XCTAssertEqual(try parser.finish(), [])
            XCTAssertThrowsError(try parser.append(Data([0])))
        }
    }

    func testMalformedOrAmbiguousHeadersAreRejected() {
        let fields = [
            "Transfer-Encoding: chunked\r\nContent-Length: 4", "Content-Length: 1\r\nContent-Length: 1",
            "Content-Length: -1", "Content-Length: +1", "Content-Length: 1, 1",
            "Content-Length: 999999999999999999999999", "Transfer-Encoding: gzip, chunked",
            "Transfer-Encoding: identity", "Content-Encoding: gzip", "Content-Length : 1",
            " Content-Length: 1", "X-Field: bad\u{0}value", "X-Field: value\nBad: value",
        ]
        for fields in fields {
            var parser = NativeHTTPResponseParser()
            XCTAssertThrowsError(try parser.append(Data("HTTP/1.1 200 OK\r\n\(fields)\r\n\r\n".utf8)))
        }
        for status in ["HTTP/2 200 OK", "HTTP/1.1 20 OK", "HTTP/1.1 200XOK", "HTTP/1.1 101 Switching Protocols"] {
            var parser = NativeHTTPResponseParser()
            XCTAssertThrowsError(try parser.append(Data("\(status)\r\n\r\n".utf8)))
        }
    }

    func testMalformedChunksAndTruncationAreRejected() throws {
        let header = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
        for chunks in ["-1\r\n", "z\r\n", "FFFFFFFFFFFFFFFFF\r\n", "1\n", "1\r\nxXX", "1;\r\n",
                       "1;a=\r\n", "1;a=\"unterminated\r\n", "0\r\nContent-Length: 4\r\n\r\n"] {
            var parser = NativeHTTPResponseParser()
            XCTAssertThrowsError(try parser.append(Data((header + chunks).utf8)))
        }
        for wire in ["HTTP/1.1 200", "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nab",
                     header + "1\r\nx\r", header + "0\r\nX-Trailer: value\r\n"] {
            var parser = NativeHTTPResponseParser()
            _ = try parser.append(Data(wire.utf8))
            XCTAssertThrowsError(try parser.finish())
        }
    }

    func testHeaderChunkLineAndTrailerLimits() throws {
        var parser = NativeHTTPResponseParser()
        XCTAssertThrowsError(try parser.append(Data(("HTTP/1.1 200 OK\r\nX: " + String(repeating: "a", count: 65536)).utf8)))
        parser = NativeHTTPResponseParser()
        let header = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
        _ = try parser.append(Data(header.utf8))
        XCTAssertThrowsError(try parser.append(Data(("1;x=" + String(repeating: "a", count: 4096)).utf8)))
        parser = NativeHTTPResponseParser()
        _ = try parser.append(Data((header + "0\r\n").utf8))
        let trailer = Data(("X: " + String(repeating: "a", count: 1000) + "\r\n").utf8)
        for _ in 0..<65 { _ = try parser.append(trailer) }
        XCTAssertThrowsError(try parser.append(trailer))
    }
}
