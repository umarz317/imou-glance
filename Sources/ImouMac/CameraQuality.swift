import Foundation

struct CameraQuality: Equatable, Identifiable {
    let streamId: Int
    let imageSize: Int
    let name: String
    let isDefault: Bool
    var id: String { "\(streamId):\(imageSize)" }
}

extension ImouCamera {
    @MainActor var qualities: [CameraQuality] {
        var result: [CameraQuality] = []
        for entry in ImouClient.mediaConfig(info).objects("streamClarity") {
            guard let streamId = Int(entry.string("streamChannel")), streamId >= 0 else { continue }
            let imageSize = Int(entry.string("imageSize")) ?? -1
            guard imageSize >= -1 else { continue }
            let name = entry.string("name").trimmingCharacters(in: .whitespacesAndNewlines)
            let height = Int(entry.string("height")) ?? 0
            let quality = CameraQuality(streamId: streamId, imageSize: imageSize,
                name: name.isEmpty ? (height > 0 ? "\(height)p" : "Stream \(streamId)") : name,
                isDefault: ["true", "1"].contains(entry.string("isDefault").lowercased()))
            if !result.contains(where: { $0.id == quality.id }) { result.append(quality) }
        }
        return result.isEmpty ? [CameraQuality(streamId: 0, imageSize: -1, name: "Default", isDefault: true)] : result
    }

    @MainActor func quality(id: String? = nil) -> CameraQuality {
        let options = qualities
        return options.first { $0.id == id } ?? options.first { $0.isDefault } ?? options[0]
    }
}
