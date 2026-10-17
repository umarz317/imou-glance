import XCTest
@testable import ImouMac

final class LoginQRCodeTests: XCTestCase {
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    @MainActor
    func testQRImageAcceptsBase64AndDataURL() {
        XCTAssertEqual(ImouClient.qrImageData(png.base64EncodedString()), png)
        XCTAssertEqual(ImouClient.qrImageData("data:image/png;base64," + png.base64EncodedString()), png)
        XCTAssertEqual(ImouClient.qrImageData(png.base64EncodedString(options: .lineLength64Characters) + "\r\n"), png)
    }

    @MainActor
    func testQRImageRejectsEmptyOrNonBase64() {
        XCTAssertNil(ImouClient.qrImageData(""))
        XCTAssertNil(ImouClient.qrImageData("data:image/png;base64,"))
    }

    @MainActor
    func testWaitingQRQueryWithoutDataIsNotAnError() throws {
        let data = try ImouClient.responseData(["code": 10000], status: 200, method: "user.account.QueryLoginQRCode")
        XCTAssertTrue(data.isEmpty)
    }
}

final class QRTerminalAuthorizationTests: XCTestCase {
    @MainActor
    func testTerminalAuthorizationOutsidePasswordSignInExplainsHowToProceed() {
        for method in ["user.account.Login", "user.account.QueryLoginQRCode"] {
            XCTAssertThrowsError(try ImouClient.responseData(["code": 12112, "data": [:]], status: 200, method: method)) { error in
                XCTAssertTrue(error.localizedDescription.contains("password"), method)
            }
        }
    }
}
