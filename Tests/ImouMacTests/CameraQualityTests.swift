import XCTest
@testable import ImouMac

final class CameraQualityTests: XCTestCase {
    @MainActor
    func testResolutionsOnTheSameStreamRemainDistinctAndKeepAdvertisedValues() {
        let camera = camera("first")
        XCTAssertEqual(camera.qualities.map(\.name), ["3MP", "1080P", "720P"])
        XCTAssertEqual(camera.qualities.map(\.id), ["0:41", "0:18", "0:17"])
        XCTAssertEqual(camera.quality().imageSize, 41)
        let selected = camera.quality(id: "0:18")
        XCTAssertEqual(selected.streamId, 0)
        XCTAssertEqual(selected.imageSize, 18)
        XCTAssertEqual(selected.name, "1080P")
    }

    @MainActor
    func testStringEncodedOptionsRejectMalformedEntriesAndPreserveDefault() {
        let camera = ImouCamera(productId: "synthetic", deviceId: "first", channelId: 0, name: "Camera",
            info: ["mediaConfig": #"{"streamClarity":[{"streamChannel":"bad","imageSize":41},{"streamChannel":0,"imageSize":18,"name":"1080P"},{"streamChannel":1,"imageSize":17,"height":720,"isDefault":"true"},{"streamChannel":1,"imageSize":17,"name":"Duplicate"}]}"#])
        XCTAssertEqual(camera.qualities.count, 2)
        XCTAssertEqual(camera.quality().id, "1:17")
        XCTAssertEqual(camera.quality().name, "720p")
        XCTAssertEqual(camera.quality(id: "unknown").id, "1:17")
        let empty = ImouCamera(productId: "synthetic", deviceId: "empty", channelId: 0, name: "Camera", info: [:])
        XCTAssertEqual(empty.quality().id, "0:-1")
    }

    @MainActor
    func testChoicesAreIndependentPerCameraAndPersistUntilCleared() {
        let first = camera("first"), second = camera("second")
        let model = PreviewModel()
        model.clearQualitySelections()
        defer { model.clearQualitySelections(); model.signOut() }
        model.cameras = [first, second]
        model.selectQuality("0:18", for: first.id)
        XCTAssertEqual(model.quality(for: first).imageSize, 18)
        XCTAssertEqual(model.quality(for: second).imageSize, 41)
        model.layout = 2
        model.selectQuality("0:17", for: second.id)
        XCTAssertEqual(model.quality(for: first).imageSize, 18)
        XCTAssertEqual(model.quality(for: second).imageSize, 17)
        model.selectQuality("0:999", for: first.id)
        XCTAssertEqual(model.quality(for: first).imageSize, 18)
        // Quitting signs out without forgetting; a new launch restores the choices.
        model.signOut()
        let relaunched = PreviewModel()
        XCTAssertEqual(relaunched.quality(for: first).imageSize, 18)
        XCTAssertEqual(relaunched.quality(for: second).imageSize, 17)
        // Explicit Sign Out (signOut(forget: true)) clears them through this method.
        relaunched.clearQualitySelections()
        XCTAssertEqual(PreviewModel().quality(for: first).imageSize, 41)
        XCTAssertEqual(PreviewModel().quality(for: second).imageSize, 41)
    }

    @MainActor
    func testRemovedQualityFallsBackToTheNewAdvertisedDefault() {
        let original = camera("first")
        var updated = original
        updated.info = ["mediaConfig": ["streamClarity": [
            ["streamChannel": "1", "imageSize": 17, "name": "720P", "isDefault": true]
        ]]]
        let model = PreviewModel()
        defer { model.signOut() }
        model.cameras = [original]
        model.selectQuality("0:18", for: original.id)
        model.cameras = [updated]
        XCTAssertEqual(model.quality(for: updated).id, "1:17")
    }

    private func camera(_ id: String) -> ImouCamera {
        ImouCamera(productId: "synthetic", deviceId: id, channelId: 0, name: "Camera",
            info: ["mediaConfig": ["streamClarity": [
                ["streamChannel": "0", "imageSize": 41, "name": "3MP", "isDefault": true],
                ["streamChannel": "0", "imageSize": 18, "name": "1080P"],
                ["streamChannel": "0", "imageSize": 17, "name": "720P"]
            ]]])
    }
}
