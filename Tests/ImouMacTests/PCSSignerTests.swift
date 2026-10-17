import XCTest
import CryptoKit
@testable import ImouMac

final class PCSSignerTests: XCTestCase {
    func testSecureRelaySchemePreservesAuthorityPortAndEncodedResource() throws {
        let suffix = "://relay.example.invalid:8556/source?encrypt=5&tid=synthetic%2Fid&token=a%2Bb%3D"
        XCTAssertEqual(try DirectStream.playerResource("rtsps" + suffix), "rtsp" + suffix)
        XCTAssertEqual(try DirectStream.playerResource("rtsp" + suffix), "rtsp" + suffix)
        let bare = "192.0.2.1:8556/live/realmonitor.rtpxav?channel=1&encrypt=5&token=synthetic%2Fid"
        XCTAssertEqual(try DirectStream.playerResource(bare), "rtsp://" + bare)
        XCTAssertEqual(try DirectStream.nativeResource(bare).absoluteString, "https://" + bare)
    }

    func testUnsupportedRelayResourcesDoNotExposeTheirContents() {
        for value in ["ftp://relay.example.invalid:8556/private-secret", "rtsps:///missing-host", "rtsp://relay.example.invalid:8556/source#private-secret", "not-a-url-private-secret"] {
            XCTAssertThrowsError(try DirectStream.playerResource(value)) { error in
                XCTAssertFalse(error.localizedDescription.contains("private-secret"))
                XCTAssertFalse(error.localizedDescription.contains("relay.example.invalid"))
            }
        }
    }

    func testNativeAuthenticationHeadersStayOutsideTheDecoderConfiguration() throws {
        var request = URLRequest(url: URL(string: "https://relay.example.invalid:8556/live/realmonitor.rtpxav")!)
        request.setValue("synthetic-private-auth", forHTTPHeaderField: "WSSE")
        let stream = DirectStream(deviceId: "synthetic-device", channelId: 0, streamId: 0, code: "",
            streamType: "rtsv", playUrl: "rtsp://relay.example.invalid:8556/live/realmonitor.rtpxav",
            nativeSessionId: "synthetic-session", nativeRequest: request)
        let encoded = try JSONEncoder().encode(stream)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["nativeSessionId"] as? String, "synthetic-session")
        XCTAssertNil(object["nativeRequest"])
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("synthetic-private-auth"))
    }

    func testTerminalAuthorizationAPIVersionIsIncludedInSignature() {
        let headers = PCSSigner(userAgent: "dGVzdA==").headers(path: "/pcs/v1/user.account.GrantingCredit",
            body: Data("{\"data\":{}}".utf8), identity: .account("test@example.com", password: "test-password"),
            session: nil, date: "2026-10-16T12:34:56Z", nonce: "123abc", apiVersion: "185612")
        XCTAssertEqual(headers["x-pcs-apiver"], "185612")
        XCTAssertEqual(headers["x-pcs-signature"], "FZ2gpzJ9H/NngTFeBjIlx2Dm59UC6ktsa5xuGN2V6yY=")
    }

    @MainActor
    func testTerminalBindingResponseRequiresUserAuthorization() {
        do {
            _ = try ImouClient.responseData(["code": 12112, "data": [:]], status: 200, method: "user.account.GetToken")
            XCTFail("Expected terminal authorization")
        } catch ImouError.terminalVerification { }
        catch { XCTFail("Incorrect terminal-verification response") }
        XCTAssertThrowsError(try ImouClient.responseData(["code": 12112, "data": [:]], status: 401, method: "user.account.GetToken"))
    }

    @MainActor
    func testCodeSendCaptchaResumesCorrectVerificationPurpose() {
        let response: [String: Any] = ["code": 12114, "data": ["captchaData": ["captchaId": "synthetic-id"]]]
        do {
            _ = try ImouClient.responseData(response, status: 200, method: "common.validcode.GetValidCode")
            XCTFail("Expected CAPTCHA before sending a code")
        } catch ImouError.captcha(let challenge) {
            XCTAssertEqual(challenge.purpose, .terminalCode)
        } catch { XCTFail("Incorrect challenge purpose") }
    }
    func testCaptchaAccountCipherMatchesIndependentNodeFixture() throws {
        let nonce = try AES.GCM.Nonce(data: Data((0..<12).map(UInt8.init)))
        XCTAssertEqual(try CaptchaCipher.encryptAccount("test@example.invalid", nonce: nonce), "AAECAwQFBgcICQoLUDjzoC8msron1v0aGedgadBJzB30qrIkoPlL7x9B7JGH8UAm")
        XCTAssertThrowsError(try CaptchaCipher.encryptAccount(""))
    }
    func testPreloginCaptchaServiceSignatureMatchesIndependentPythonFixture() {
        let headers = PCSSigner(userAgent: "synthetic-ua").headers(
            path: "/pcs/v1/common.validcode.CheckGeeTest4",
            body: Data(#"{"data":{"captchaId":"synthetic-id","usage":"Login"}}"#.utf8),
            identity: VerificationProtocol.identity, session: nil,
            date: "2026-10-17T00:00:00Z", nonce: "synthetic-nonce",
            apiVersion: VerificationProtocol.captchaAPIVersion)
        XCTAssertTrue(headers["x-pcs-username"]?.hasPrefix("default\\") == true)
        XCTAssertEqual(headers["x-pcs-apiver"], "3.10.0")
        XCTAssertNil(headers["x-pcs-session-id"])
        XCTAssertEqual(headers["x-pcs-signature"], "2/qkFfGaiETDtFQSRkqa8VKJaSNOZGK9FE4944b7CJs=")
        XCTAssertEqual(headers["x-pcs-signature-sha256"], "8PiD/nQAsxalFGQUIUeWjids4axdJ1FERw5T59YV3Do=")
    }
    @MainActor
    func testImouCaptchaResponsePreservesChallengeWithoutExposingItInError() {
        let object: [String: Any] = ["code": 12114, "data": ["captchaData": ["captchaId": "synthetic-id", "verifyToken": "synthetic-token"], "captchaMetaData": "synthetic-metadata"]]
        do {
            _ = try ImouClient.responseData(object, status: 200, method: "user.account.GetToken")
            XCTFail("Expected a human verification challenge")
        } catch ImouError.captcha(let challenge) {
            XCTAssertEqual(challenge.captchaId, "synthetic-id")
            XCTAssertEqual(challenge.verifyToken, "synthetic-token")
            XCTAssertEqual(challenge.metadata, "synthetic-metadata")
            XCTAssertFalse(ImouError.captcha(challenge).localizedDescription.contains("synthetic-token"))
        } catch { XCTFail("Incorrect challenge response: \(error)") }
    }
    @MainActor
    func testPCSSuccessEnvelopeCanStillContainRejectedLogin() throws {
        let data = try ImouClient.responseData(["code": 10000, "data": ["failNum": 1]], status: 200, method: "user.account.GetToken")
        XCTAssertEqual(data.string("failNum"), "1")
        XCTAssertThrowsError(try ImouClient.responseData(["code": 11001, "data": [:]], status: 200, method: "user.account.GetToken"))
        XCTAssertThrowsError(try ImouClient.responseData(["code": 10000], status: 200, method: "test"))
        XCTAssertThrowsError(try ImouClient.responseData(["code": 10000, "data": [:]], status: 401, method: "test"))
        XCTAssertNoThrow(try ImouClient.responseData(["code": 10000], status: 200, method: "common.validcode.CheckGeeTest4"))
    }
    func testLegacyCameraSecretFixtureAndUnsupportedGCM() {
        let wire = "k0XaM7oUbelSfRYNjmsRe56nSp7HRI4N8GwWFnYI9rM="
        XCTAssertEqual(DeviceSecret.decode(deviceId: "test-serial", wire: wire, encryptMode: 0), "TEST-CAMERA-CODE")
        XCTAssertNil(DeviceSecret.decode(deviceId: "test-serial", wire: wire, encryptMode: 5))
        XCTAssertNil(DeviceSecret.decode(deviceId: "wrong-serial", wire: wire, encryptMode: 0))
        XCTAssertNil(DeviceSecret.decode(deviceId: "test-serial", wire: "invalid", encryptMode: 0))
    }
    func testConsumerCredentialAndSignatureVectors() {
        // Independent Python hashlib/hmac fixtures; these contain no real account data.
        let identity = PCSIdentity.account("test@example.com", password: "test-password")
        XCTAssertEqual(identity.username, "account\\test@example.com")
        XCTAssertEqual(identity.md5Key, "236442808fcd83d3a2b844b4daec845d")
        XCTAssertEqual(identity.sha256Key, "f336ec93ff5f69d69e97d64e4a02161f8c21fa6a3c5be80593e012eeaef0e811")
        let signer = PCSSigner(userAgent: "dGVzdA==")
        let headers = signer.headers(path: "/pcs/v1/user.account.GetToken", body: Data("{\"data\":{}}".utf8), identity: identity,
                                     session: nil, date: "2026-10-16T12:34:56Z", nonce: "123abc")
        XCTAssertEqual(headers["Content-MD5"], "Odw3OaFlWAlWzvmcB+wsgQ==")
        XCTAssertEqual(headers["Content-SHA256"], "f7nRZtGhW84LnwhfOBiUb9kpfkUTpKA0oM63SSkrTA0=")
        XCTAssertEqual(headers["x-pcs-signature"], "Yk7xmF98pgM5BONHGy+plarCFM0ueRRUQ/kJh+PVAtg=")
        XCTAssertEqual(headers["x-pcs-signature-sha256"], "cQOaZnNWF1ar3OVZPhfVTQCreV01aL7oPajlU0iRztw=")
        XCTAssertNil(headers["x-pcs-session-id"])
    }

    func testTokenIsOnlyHashedOnceAndSessionIsSignedInOrder() {
        let token = PCSIdentity.token("user-id", token: "abc")
        XCTAssertEqual(token.username, "uuid\\user-id")
        XCTAssertEqual(token.md5Key, "900150983cd24fb0d6963f7d28e17f72")
        let canonical = PCSSigner.canonical(path: "/pcs/v1/test", digest: "digest", userAgent: "agent", date: "date", nonce: "nonce", username: token.username, session: "session")
        XCTAssertEqual(canonical, "POST\n/pcs/v1/test\ndigest\napplication/json\nx-pcs-apiver:0\nx-pcs-client-ua:agent\nx-pcs-date:date\nx-pcs-nonce:nonce\nx-pcs-session-id:session\nx-pcs-username:uuid\\user-id\n")
    }

    @MainActor
    func testRegionalCredentialsStayOnImouHTTPSHosts() throws {
        XCTAssertEqual(try ImouClient.validatedHost("app-v2.easy4ipcloud.com:443").host, "app-v2.easy4ipcloud.com")
        XCTAssertThrowsError(try ImouClient.validatedHost("http://app-v2.easy4ipcloud.com"))
        XCTAssertThrowsError(try ImouClient.validatedHost("https://easy4ipcloud.com.evil.example"))
        XCTAssertThrowsError(try ImouClient.validatedHost("https://evil.example@easy4ipcloud.com"))
        XCTAssertThrowsError(try ImouClient.validatedHost("https://app-v2.easy4ipcloud.com/path"))
    }

    @MainActor
    func testEncodedMediaConfigKeepsEncryptionAndStreamMetadata() {
        let object = ImouClient.mediaConfig(["mediaConfig": "{\"streamEncryModel\":1,\"streamProtocol\":[1],\"streamClarity\":[{\"streamChannel\":1,\"imageSize\":5,\"isDefault\":true}]}"])
        XCTAssertEqual(object.string("streamEncryModel"), "1")
        XCTAssertEqual(object.objects("streamClarity").first?.string("streamChannel"), "1")
        XCTAssertTrue(ImouClient.mediaConfig(["mediaConfig": "invalid"]).isEmpty)
    }
}
