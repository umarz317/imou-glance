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

final class SavedSessionTests: XCTestCase {
    func testSessionRoundTripAndDelete() throws {
        let service = "local.imou.peek.tests.\(UUID().uuidString)"
        defer { SavedSession.delete(service: service) }
        let session = SavedSession(username: "synthetic-user", token: "synthetic-token", sessionId: "synthetic-session",
                                   host: "https://app-v2.easy4ipcloud.com")
        try session.save(service: service)
        XCTAssertEqual(SavedSession.load(service: service), session)
        SavedSession.delete(service: service)
        XCTAssertNil(SavedSession.load(service: service))
    }
}
