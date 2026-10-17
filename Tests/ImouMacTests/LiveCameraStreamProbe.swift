import XCTest
@testable import ImouMac

/// Opt-in live probe: IMOU_LIVE_CAMERA="Main Gate" swift test --filter LiveCameraStreamProbe
/// Uses the QR session saved in the Keychain, prints non-secret camera fields, then counts relay packets for 20 s.
final class LiveCameraStreamProbe: XCTestCase {
    /// Allow-list only: device records also carry nested tokens and credentials.
    private static let safeKeys = ["deviceModel", "status", "catalog", "channelNum", "channelName", "name"]

    private static func describe(_ info: [String: Any]) -> String {
        safeKeys.map { "\($0)=\(info.string($0))" }.joined(separator: " | ")
    }

    @MainActor
    func testStreamDelivery() async throws {
        let target = ProcessInfo.processInfo.environment["IMOU_LIVE_CAMERA"] ?? ""
        try XCTSkipIf(target.isEmpty, "Live probe disabled")
        let saved = try XCTUnwrap(SavedSession.load(), "No saved QR session")
        let client = ImouClient()
        try await client.resume(saved)
        let cameras = try await client.cameras()
        print("CAMPROBE cameras=\(cameras.map(\.name))")
        for camera in cameras where camera.name == target || camera.id == cameras.first(where: { $0.name != target })?.id {
            print("CAMPROBE ==== \(camera.name) channel=\(camera.channelId)")
            print("CAMPROBE info: \(Self.describe(camera.info))")
            let media = ImouClient.mediaConfig(camera.info)
            print("CAMPROBE media: streamEncryModel=\(media.string("streamEncryModel")) maxClarity=\(media.string("maxClarity")) hardDecodeSupport=\(media.string("hardDecodeSupport"))")
            print("CAMPROBE qualities: \(camera.qualities.map { "\($0.id):\($0.name)" })")
            do {
                LegacyRelayCertificate.approvedForRun = true
                let stream = try await client.stream(for: camera, code: "")
                let encrypt = URLComponents(string: stream.playUrl)?.queryItems?.filter { $0.name == "encrypt" } ?? []
                print("CAMPROBE stream ok host=\(URLComponents(string: stream.playUrl)?.host ?? "?") encrypt=\(encrypt) playToken=\(!(stream.playToken ?? "").isEmpty) password=\(!(stream.deviceLoginPassword ?? "").isEmpty)")
                guard let request = stream.nativeRequest else { print("CAMPROBE no native request"); continue }
                var packets = 0, bytes = 0, opened = false, errors: [String] = []
                let transport = NativeMediaTransport(onOpen: { opened = true },
                                                     onPacket: { packets += 1; bytes += $0.count },
                                                     onError: { errors.append($0) })
                transport.start(request)
                try await Task.sleep(for: .seconds(20))
                transport.stop()
                print("CAMPROBE relay opened=\(opened) packets=\(packets) bytes=\(bytes) errors=\(errors)")
            } catch {
                print("CAMPROBE stream error: \(error.localizedDescription)")
            }
        }
    }
}
