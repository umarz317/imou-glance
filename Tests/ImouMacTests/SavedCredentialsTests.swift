import XCTest
@testable import ImouMac

final class SavedCredentialsTests: XCTestCase {
    func testKeychainRoundTripAndDelete() throws {
        let service = "local.imou.peek.tests.\(UUID().uuidString)"
        defer { SavedCredentials.delete(service: service) }
        let first = SavedCredentials(account: "user@example.invalid", password: "first", areaCode: "")
        try first.save(service: service)
        XCTAssertEqual(SavedCredentials.load(service: service), first)
        let second = SavedCredentials(account: "3001234567", password: "second", areaCode: "+92")
        try second.save(service: service)
        XCTAssertEqual(SavedCredentials.load(service: service), second)
        SavedCredentials.delete(service: service)
        XCTAssertNil(SavedCredentials.load(service: service))
    }
}
