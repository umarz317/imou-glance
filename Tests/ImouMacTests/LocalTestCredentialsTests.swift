import XCTest
@testable import ImouMac

final class LocalTestCredentialsTests: XCTestCase {
    func testLiteralValuesAreNotShellInterpretedOrTrimmed() throws {
        let credentials = try LocalTestCredentials(contents: "# Synthetic fixture\r\nIMOU_EMAIL=test@example.invalid\r\nIMOU_PASSWORD= $x='quote'#=\\literal \r\nIMOU_COUNTRY_CODE=+92\r\n")
        XCTAssertEqual(credentials.account, "test@example.invalid")
        XCTAssertEqual(credentials.password, " $x='quote'#=\\literal ")
        XCTAssertEqual(credentials.countryCode, "+92")
    }

    func testMissingDuplicateAndUnknownFieldsAreRejectedWithoutEchoingValues() throws {
        for contents in ["IMOU_EMAIL=test@example.invalid", "IMOU_EMAIL=a\nIMOU_PASSWORD=\n",
                         "IMOU_EMAIL=a\nIMOU_PASSWORD=synthetic\nIMOU_PASSWORD=duplicate",
                         "IMOU_EMAIL=a\nIMOU_PASSWORD=synthetic\nUNEXPECTED=secret"] {
            XCTAssertThrowsError(try LocalTestCredentials(contents: contents)) { error in
                XCTAssertFalse(error.localizedDescription.contains("synthetic"))
                XCTAssertFalse(error.localizedDescription.contains("secret"))
            }
        }
    }
}
