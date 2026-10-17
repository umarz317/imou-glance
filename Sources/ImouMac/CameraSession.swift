import Foundation

extension ImouClient {
    func cameras() async throws -> [ImouCamera] {
        var all: [[String: Any]] = []
        var cursor: Int64 = -1
        var seen = Set<Int64>()
        while true {
            let page = try await request("device.list.BasicPageGet", data: ["bindId": cursor, "limit": 50, "familyId": "-1"])
            guard let devices = page["deviceList"] as? [[String: Any]] else {
                throw ImouError.message("Imou returned an unsupported camera list.")
            }
            if devices.isEmpty { break }
            for device in devices {
                if let index = all.firstIndex(where: { $0.string("deviceId") == device.string("deviceId") && $0.string("productId") == device.string("productId") }) {
                    var channels = all[index].objects("channelList")
                    for channel in device.objects("channelList") where !channels.contains(where: { $0.string("channelId") == channel.string("channelId") }) {
                        channels.append(channel)
                    }
                    all[index]["channelList"] = channels
                } else { all.append(device) }
            }
            guard let next = Int64(devices.last!.string("bindId")), seen.insert(next).inserted,
                  all.count <= 5000, seen.count <= 5000 else { throw ImouError.message("Imou returned an invalid camera list cursor.") }
            cursor = next
        }
        var result: [ImouCamera] = []
        for start in stride(from: 0, to: all.count, by: 50) {
            let batch = Array(all[start..<min(start + 50, all.count)])
            let ids: [[String: Any]] = try batch.map { device in
                ["productId": try device.required("productId"), "deviceId": try device.required("deviceId"),
                 "channelList": device.objects("channelList").map { $0.string("channelId") }]
            }
            let detail = try await request("device.list.CommonInfoGetByIds", data: ["deviceList": ids, "needNewSecret": true])
            guard let devices = detail["deviceList"] as? [[String: Any]] else {
                throw ImouError.message("Imou returned unsupported camera details.")
            }
            for device in devices {
                let deviceId = try device.required("deviceId")
                let productId = try device.required("productId")
                let basic = batch.first { $0.string("deviceId") == deviceId && $0.string("productId") == productId } ?? [:]
                let channels = device.objects("channelList").isEmpty ? basic.objects("channelList") : device.objects("channelList")
                for channel in channels {
                    guard let channelId = Int(channel.string("channelId")), channelId >= 0 else { continue }
                    var merged = device
                    merged.merge(channel) { _, channelValue in channelValue }
                    let deviceName = device.string("name")
                    let channelName = channel.string("channelName")
                    let name = channelName.isEmpty ? (deviceName.isEmpty ? "Camera \(result.count + 1)" : deviceName) : channelName
                    result.append(ImouCamera(productId: productId, deviceId: deviceId, channelId: channelId, name: name, info: merged))
                }
            }
        }
        return result
    }

    func stream(for camera: ImouCamera, code: String, qualityID: String? = nil) async throws -> DirectStream {
        let media = Self.mediaConfig(camera.info)
        guard let mode = Int(media.string("streamEncryModel")), [0, 1, 3, 5].contains(mode) else {
            throw ImouError.unsupported("This camera uses an unsupported stream encryption configuration.")
        }
        let protocolValue = media["streamProtocol"]
        let advertised = protocolValue as? [Any] ?? protocolValue.map { [$0] } ?? []
        let protocols = advertised.compactMap { Int(String(describing: $0)) }
        guard protocols.contains(1) else {
            throw ImouError.unsupported("This camera does not advertise the RTSV transport required by the embedded player.")
        }
        let quality = camera.quality(id: qualityID)
        let streamId = quality.streamId
        let imageSize = quality.imageSize
        let data: [String: Any] = ["productId": camera.productId, "deviceId": camera.deviceId,
                                  "channelId": String(camera.channelId), "streamId": String(streamId),
                                  "encrypt": String(mode == 1 ? 2 : mode), "type": "RTSV1", "windowNum": "1",
                                  "design": "first", "assistStream": "true", "imageSize": imageSize,
                                  "audioType": 0, "timeLimit": false, "videoLimit": 0]
        let resource = try await request("things.media.GetRealTransferStreamUrl", data: data)
        let url = try DirectStream.playerResource(resource.required("tls_resource"))
        let playToken = resource["playToken"] as? String
        let playTokenKey = resource["playTokenKey"] as? String
        let hasPlaybackCredentials = !(playToken ?? "").isEmpty && !(playTokenKey ?? "").isEmpty
        var secret = code.isEmpty ? (DeviceSecret.decode(deviceId: camera.deviceId, wire: camera.info.string("devicePassword"), encryptMode: Int(camera.info.string("encryptMode")) ?? 0) ?? "") : code
        if secret.isEmpty && !hasPlaybackCredentials {
            let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
            let salt = String((0..<16).map { _ in alphabet.randomElement()! })
            let password = try await request("iot.control.DevicePasswordGet", data: [
                "productId": camera.productId, "deviceId": camera.deviceId,
                "channelId": String(camera.channelId), "salt": salt
            ])
            guard let recovered = DeviceSecret.decodeResponse(deviceId: camera.deviceId,
                wire: password.string("devicePassword"), encType: Int(password.string("encType")) ?? 0, salt: salt) else {
                throw ImouError.message("Could not decrypt the camera password returned by Imou.")
            }
            secret = recovered
        }
        let loginName = DeviceSecret.decode(deviceId: camera.deviceId,
            wire: camera.info.string("deviceUsername"), encryptMode: 0) ?? media.string("deviceAccount")
        let request = try NativeStreamAuthentication.request(resource: resource.required("tls_resource"), username: loginName)
        return DirectStream(deviceId: camera.deviceId, channelId: camera.channelId,
                            streamId: streamId, code: "", streamType: "rtsv", playUrl: url,
                            playToken: playToken, playTokenKey: playTokenKey,
                            deviceLoginName: loginName, deviceLoginPassword: secret,
                            nativeSessionId: UUID().uuidString, nativeRequest: request)
    }

    static func mediaConfig(_ info: [String: Any]) -> [String: Any] {
        if let object = info["mediaConfig"] as? [String: Any] { return object }
        if let data = info.string("mediaConfig").data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return object }
        return [:]
    }
}
