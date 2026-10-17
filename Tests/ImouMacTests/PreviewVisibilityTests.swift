import XCTest
@testable import ImouMac

final class PreviewVisibilityTests: XCTestCase {
    @MainActor
    func testClosingOnePreviewKeepsAnotherVisible() {
        let model = PreviewModel()
        let window = UUID(), popover = UUID()
        model.setVisible(true, view: window)
        model.setVisible(true, view: window)
        model.setVisible(true, view: popover)
        model.setVisible(false, view: popover)
        XCTAssertTrue(model.visible)
        model.setVisible(false, view: window)
        XCTAssertFalse(model.visible)
    }
}
