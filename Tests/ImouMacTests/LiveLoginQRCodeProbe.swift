import XCTest
@testable import ImouMac

/// Opt-in live probe: IMOU_LIVE_QR=1 swift test --filter LiveLoginQRCodeProbe
/// Requests a real QR code, never scans it, and logs each status until Imou expires it.
final class LiveLoginQRCodeProbe: XCTestCase {
    @MainActor
    func testUnscannedCodeStatusesUntilExpiry() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IMOU_LIVE_QR"] == "1", "Live probe disabled")
        let client = ImouClient()
        let qr = try await client.loginQRCode(size: 360)
        print("QRPROBE image bytes=\(qr.image.count) png=\(qr.image.starts(with: [0x89, 0x50, 0x4E, 0x47]))")
        let start = Date()
        while Date().timeIntervalSince(start) < 420 {
            do {
                let data = try await client.request("user.account.QueryLoginQRCode", data: ["loginCode": qr.code], verification: true)
                print("QRPROBE t=\(Int(Date().timeIntervalSince(start))) status=\(data.string("status")) keys=\(data.keys.sorted())")
                if data.string("status") == "expire" { return }
            } catch {
                print("QRPROBE t=\(Int(Date().timeIntervalSince(start))) error=\(error.localizedDescription)")
            }
            try await Task.sleep(for: .seconds(15))
        }
    }
}
