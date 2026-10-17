import XCTest
@testable import ImouMac

final class LegacyRelayCertificateTests: XCTestCase {
    func testExceptionRequiresActiveSessionAndExactCertificate() {
        let known = LegacyRelayCertificate.fingerprint
        XCTAssertFalse(LegacyRelayCertificate.permits(known, approved: false))
        XCTAssertTrue(LegacyRelayCertificate.permits(known, approved: true))
        XCTAssertFalse(LegacyRelayCertificate.permits(String(repeating: "0", count: 64), approved: true))
        XCTAssertFalse(LegacyRelayCertificate.permits(nil, approved: true))
    }

    @MainActor
    func testSignOutClearsCertificateApproval() {
        let model = PreviewModel()
        model.signedIn = true
        XCTAssertTrue(LegacyRelayCertificate.approvedForRun)
        model.signOut()
        XCTAssertFalse(LegacyRelayCertificate.approvedForRun)
    }

    @MainActor
    func testSignInAutomaticallyAllowsKnownCertificateAndSurvivesMediaReconnect() {
        let model = PreviewModel()
        defer { model.signOut() }
        model.signOut()
        XCTAssertFalse(LegacyRelayCertificate.approvedForRun)
        model.signedIn = true
        XCTAssertTrue(LegacyRelayCertificate.approvedForRun)
        model.stream = stream("current")
        model.stream = stream("reconnected")
        model.status = "Connecting…"
        XCTAssertTrue(LegacyRelayCertificate.approvedForRun)
        XCTAssertTrue(LegacyRelayCertificate.permits(LegacyRelayCertificate.fingerprint,
                                                    approved: LegacyRelayCertificate.approvedForRun))
    }

    @MainActor
    func testNewSessionReenablesExceptionAndShutdownClearsIt() {
        let model = PreviewModel()
        defer { model.signOut() }
        model.signedIn = true
        model.signOut()
        XCTAssertFalse(LegacyRelayCertificate.approvedForRun)
        model.signedIn = true
        XCTAssertTrue(LegacyRelayCertificate.approvedForRun)
        model.shutdown()
        XCTAssertFalse(LegacyRelayCertificate.approvedForRun)
    }

    private func stream(_ id: String) -> DirectStream {
        DirectStream(deviceId: "synthetic", channelId: 0, streamId: 0, code: "",
                     streamType: "rtsv", playUrl: "rtsp://relay.invalid:443/live/test",
                     nativeSessionId: id)
    }
}
