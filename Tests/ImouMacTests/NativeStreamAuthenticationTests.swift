import XCTest
@testable import ImouMac

final class NativeStreamAuthenticationTests: XCTestCase {
    @MainActor
    func testTLSFailureOnlyExposesNumericDiagnostics() {
        let underlying = NSError(domain: "kCFErrorDomainCFNetwork", code: -1200,
            userInfo: ["_kCFStreamErrorCodeKey": -9824, NSURLErrorFailingURLStringErrorKey: "https://private-relay.invalid/secret-token"])
        let error = NSError(domain: NSURLErrorDomain, code: -1200,
            userInfo: [NSUnderlyingErrorKey: underlying, NSLocalizedDescriptionKey: "private diagnostic"])
        XCTAssertEqual(NativeMediaTransport.secureFailureMessage(error), "Secure camera connection failed (-1200; TLS -9824).")
    }

    func testRemoteWSSEV2MatchesIndependentPythonFixture() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-17T00:00:00Z"))
        let request = try NativeStreamAuthentication.request(
            resource: "192.0.2.1:8556/live/realmonitor.rtpxav?channel=0&encrypt=5",
            username: "test-device-user", date: date, nonce: "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(request.url?.absoluteString,
            "https://192.0.2.1:8556/live/realmonitor.rtpxav?channel=0&encrypt=5&method=0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "WSSE profile=\"UsernameTokenV2\"")
        XCTAssertEqual(request.value(forHTTPHeaderField: "WSSE"),
            "UsernameToken Username=\"test-device-user\", PasswordDigest=\"3m4DnmVSnESzJYTjTgeMPqVZcAMPGjs5fC3083CIoGU=\", Nonce=\"0123456789abcdef0123456789abcdef\", Created=\"20261017T000000Z\"")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accpet-Sdp"), "Private")
    }

    func testSignedTargetKeepsEncodedResourceAndRefusesInvalidCredentials() throws {
        let request = try NativeStreamAuthentication.request(
            resource: "192.0.2.1:8556/live/realmonitor.rtpxav?token=synthetic%2Fid%2Bvalue",
            username: "synthetic-user")
        XCTAssertEqual(request.url?.absoluteString,
            "https://192.0.2.1:8556/live/realmonitor.rtpxav?token=synthetic%2Fid%2Bvalue&method=0")
        XCTAssertThrowsError(try NativeStreamAuthentication.request(resource: "192.0.2.1:8556/source", username: ""))
        XCTAssertThrowsError(try NativeStreamAuthentication.request(resource: "192.0.2.1:8556/source", username: "bad\r\nname"))
        XCTAssertThrowsError(try NativeStreamAuthentication.request(resource: "192.0.2.1:8556/source?method=3", username: "user"))
    }
}
