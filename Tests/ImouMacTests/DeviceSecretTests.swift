import XCTest
@testable import ImouMac

final class DeviceSecretTests: XCTestCase {
    // Independent Node.js crypto fixtures, using nonce 000102030405060708090a0b and synthetic inputs.
    private let salt = "AbC012xYz987Qwer"
    private let wire = "AAECAwQFBgcICQoLUBGSZqiYw8Zy/uY+kUpOIx2ORo8vu4jwnxcImwARCMYTGZMI"

    func testSaltedGCMResponse() {
        XCTAssertEqual(DeviceSecret.decodeResponse(deviceId: "test-serial", wire: wire, encType: 2, salt: salt),
                       "TEST-GCM-CAMERA-CODE")
        XCTAssertNil(DeviceSecret.decodeResponse(deviceId: "wrong-serial", wire: wire, encType: 2, salt: salt))
        XCTAssertNil(DeviceSecret.decodeResponse(deviceId: "test-serial", wire: wire, encType: 2, salt: "wrong-salt"))
        XCTAssertNil(DeviceSecret.decodeResponse(deviceId: "test-serial", wire: wire, encType: 2, salt: ""))
    }

    func testRejectsMalformedAndUnauthenticatedResponse() {
        XCTAssertNil(DeviceSecret.decodeResponse(deviceId: "test-serial", wire: "invalid", encType: 2, salt: salt))
        XCTAssertNil(DeviceSecret.decodeResponse(deviceId: "test-serial", wire: "AAECAwQFBgcICQoL", encType: 2, salt: salt))
        var tampered = Data(base64Encoded: wire)!
        tampered[tampered.count - 1] ^= 1
        XCTAssertNil(DeviceSecret.decodeResponse(deviceId: "test-serial", wire: tampered.base64EncodedString(), encType: 2, salt: salt))
        let control = "AAECAwQFBgcICQoLaD2vV4+98u4+1gNVAReIu+mxwdvpz0GX+74="
        XCTAssertNil(DeviceSecret.decodeResponse(deviceId: "test-serial", wire: control, encType: 2, salt: salt))
        let empty = "AAECAwQFBgcICQoLvp3DEXkPTWDkqDOGwKZ7eQ=="
        XCTAssertNil(DeviceSecret.decodeResponse(deviceId: "test-serial", wire: empty, encType: 2, salt: salt))
    }

    func testNonGCMResponseUsesLegacyDecoder() {
        let legacy = "k0XaM7oUbelSfRYNjmsRe56nSp7HRI4N8GwWFnYI9rM="
        for encType in [0, 1, 5] {
            XCTAssertEqual(DeviceSecret.decodeResponse(deviceId: "test-serial", wire: legacy, encType: encType, salt: ""),
                           "TEST-CAMERA-CODE")
        }
        XCTAssertNil(DeviceSecret.decode(deviceId: "test-serial", wire: wire, encryptMode: 5))
    }
}
