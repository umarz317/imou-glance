import XCTest
@testable import ImouMac

final class LegacyRelayConnectionTests: XCTestCase {
    @MainActor
    func testRequestPreservesTheSignedTargetAndHeaders() throws {
        let request = try NativeStreamAuthentication.request(
            resource: "relay.invalid:443/live/realmonitor.rtpxav?a=one%2Ftwo&b=%2B+",
            username: "synthetic")
        let bytes = try LegacyRelayConnection.wireRequest(request)
        let wire = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(wire.hasPrefix("GET /live/realmonitor.rtpxav?a=one%2Ftwo&b=%2B+&method=0 HTTP/1.1\r\n"))
        XCTAssertTrue(wire.contains("\r\nHost: relay.invalid:443\r\n"))
        XCTAssertTrue(wire.contains("\r\nWSSE: " + request.value(forHTTPHeaderField: "WSSE")! + "\r\n"))
        XCTAssertTrue(wire.hasSuffix("\r\n\r\n"))
        XCTAssertFalse(wire.contains("https://"))
    }

    @MainActor
    func testNoCleartextRedirectBodyOrAmbiguousRequestFraming() throws {
        var request = URLRequest(url: URL(string: "http://relay.invalid:443/live/test")!)
        request.httpMethod = "GET"
        XCTAssertThrowsError(try LegacyRelayConnection.wireRequest(request))
        request.url = URL(string: "https://relay.invalid:443/live/test")!
        request.httpBody = Data([1])
        XCTAssertThrowsError(try LegacyRelayConnection.wireRequest(request))
        request.httpBody = nil
        request.setValue("chunked", forHTTPHeaderField: "Transfer-Encoding")
        XCTAssertThrowsError(try LegacyRelayConnection.wireRequest(request))
    }

    @MainActor
    func testDefaultOffCannotStartTheLegacyConnection() {
        LegacyRelayCertificate.approvedForRun = false
        var failed = false
        let connection = LegacyRelayConnection(onResponse: { _, _, _ in XCTFail(); return false },
            onData: { _ in XCTFail() }, onError: { _ in failed = true })
        connection.start(URLRequest(url: URL(string: "https://relay.invalid:443/live/test")!))
        XCTAssertTrue(failed)
        connection.stop()
    }
}
