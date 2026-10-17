import Foundation

struct ImouCamera: Identifiable {
    var id: String { productId + ":" + deviceId + ":" + String(channelId) }
    let productId: String
    let deviceId: String
    let channelId: Int
    let name: String
    var info: [String: Any]
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class ImouClient {
    private let redirectDelegate = NoRedirects()
    private lazy var transport: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 35
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: redirectDelegate, delegateQueue: nil)
    }()
    private var host = URL(string: "https://app-v2.easy4ipcloud.com")!
    private var identity: PCSIdentity?
    private var sessionId: String?
    private var clockOffset: TimeInterval = 0
    private var generation = UUID()
    private var pendingSignInData: [String: Any]?
    /// The current session in a form that can be restored on the next launch.
    private(set) var savedSession: SavedSession?
    private let signer: PCSSigner

    init() {
        let defaults = UserDefaults.standard
        let terminalId = defaults.string(forKey: "direct.terminalId") ?? UUID().uuidString
        defaults.set(terminalId, forKey: "direct.terminalId")
        // Use the shipped client's PC protocol metadata for compatibility.
        let ua = ["clientType": "pc", "clientVersion": "6.1.8", "clientOS": "Windows",
                  "clientOV": "Windows 10", "terminalModel": "Windows 10",
                  "terminalId": terminalId, "appid": "easy4ipbasepc", "terminalName": "Imou Peek for Mac",
                  "project": "Base", "language": "en", "clientProtocolVersion": "V9.7.0",
                  "timezoneOffset": String(TimeZone.current.secondsFromGMT() / 60), "clientOSBits": "64"]
        let data = try! JSONSerialization.data(withJSONObject: ua, options: [.sortedKeys, .withoutEscapingSlashes])
        signer = PCSSigner(userAgent: data.base64EncodedString())
    }

    static func validatedHost(_ value: String) throws -> URL {
        let raw = value.contains("://") ? value : "https://" + value
        guard let url = URL(string: raw), url.scheme == "https", let hostname = url.host?.lowercased(),
              ["easy4ipcloud.com", "imoulife.com"].contains(where: { hostname == $0 || hostname.hasSuffix("." + $0) }),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw ImouError.message("Imou returned an unsupported account server.")
        }
        return url
    }

    func signIn(account: String, password: String, areaCode: String) async throws {
        signOut()
        let run = generation
        guard !account.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ImouError.message("Enter your Imou email or phone number on one line.")
        }
        identity = .account(account, password: password)
        pendingSignInData = ["gpsInfo": ["longitude": 0.0, "latitude": 0.0], "areaCode": areaCode]
        do {
            try await finishSignIn()
        } catch ImouError.captcha(let challenge) {
            throw ImouError.captcha(challenge)
        } catch ImouError.terminalVerification {
            throw ImouError.terminalVerification
        } catch {
            if generation == run { signOut() }
            throw error
        }
    }

    private func finishSignIn() async throws {
        guard let pendingSignInData else { throw ImouError.message("Sign in again to start verification.") }
        let data = try await request("user.account.GetToken", data: pendingSignInData)
        if !data.string("failNum").isEmpty {
            throw ImouError.message(data.string("failNum") == "5" ? "Imou has temporarily locked sign-in. Try again later." : "Imou did not accept the account or password.")
        }
        try await startSession(data)
        self.pendingSignInData = nil
    }

    /// Shared by password and QR sign-in: both responses carry username, token, sessionId and an optional entry URL.
    private func startSession(_ data: [String: Any]) async throws {
        let username = try data.required("username")
        let token = try data.required("token")
        sessionId = try data.required("sessionId")
        identity = .token(username, token: token)
        if !data.string("entryUrl").isEmpty { host = try Self.validatedHost(data.string("entryUrl")) }
        else if !data.string("entryUrlV2").isEmpty { host = try Self.validatedHost(data.string("entryUrlV2")) }
        try await login()
        savedSession = SavedSession(username: username, token: token, sessionId: sessionId ?? "", host: host.absoluteString)
    }

    private func login() async throws {
        let login = try await request("user.account.Login", data: ["timezoneOffset": NSNull()])
        if !login.string("entryUrl").isEmpty { host = try Self.validatedHost(login.string("entryUrl")) }
        else if !login.string("entryUrlV2").isEmpty { host = try Self.validatedHost(login.string("entryUrlV2")) }
    }

    /// Restores a session saved after a QR sign-in; Login confirms Imou still accepts it.
    func resume(_ saved: SavedSession) async throws {
        signOut()
        host = try Self.validatedHost(saved.host)
        identity = .token(saved.username, token: saved.token)
        sessionId = saved.sessionId
        try await login()
        savedSession = SavedSession(username: saved.username, token: saved.token, sessionId: saved.sessionId, host: host.absoluteString)
    }

    // QR sign-in, as in the Windows client (LCBaseLogic OnRequestGetLoginORCode / OnRequestQueryLoginORCode):
    // both calls use the pre-login service identity; the phone app scans the code and approves it.

    /// Starts a QR sign-in and returns the code to poll plus the PNG Imou rendered for it.
    func loginQRCode(size: Int) async throws -> (code: String, image: Data) {
        signOut()
        let data = try await qrRequest("user.account.GetLoginQRCode", data: ["width": size, "height": size], apiVersion: "138591")
        let code = data.string("loginCode")
        guard !code.isEmpty, let image = Self.qrImageData(data.string("QRCodeImage")) else {
            throw ImouError.message(Self.qrUnavailable + " Imou returned a QR code this app cannot read.")
        }
        return (code, image)
    }

    /// Checks a QR sign-in once. Returns true once signed in, false while the code is still waiting.
    func pollLoginQRCode(_ code: String) async throws -> Bool {
        let data = try await qrRequest("user.account.QueryLoginQRCode", data: ["loginCode": code])
        switch data.string("status") {
        case "login":
            try await startSession(data)
            return true
        case "cancel": throw ImouError.message("Sign-in was declined in the Imou app.")
        case "expire": throw ImouError.message("The QR code expired. Show a new one to try again.")
        default: return false
        }
    }

    static let qrUnavailable = "QR sign-in is not available right now; Imou may have changed it. Sign in with your email or phone instead."

    /// QR calls use Imou's private API; a rejection names the fallback instead of a bare error code.
    private func qrRequest(_ method: String, data: [String: Any], apiVersion: String = "0") async throws -> [String: Any] {
        do {
            return try await request(method, data: data, verification: true, apiVersion: apiVersion)
        } catch ImouError.message(let detail) {
            throw ImouError.message(Self.qrUnavailable + " (" + detail + ")")
        }
    }

    /// QRCodeImage is Base64 image data, optionally as a data URL.
    static func qrImageData(_ value: String) -> Data? {
        let payload = value.range(of: ";base64,").map { String(value[$0.upperBound...]) } ?? value
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters), !data.isEmpty else { return nil }
        return data
    }

    func verifyCaptcha(_ challenge: CaptchaChallenge, result: [String: Any]) async throws -> Bool {
        guard let identity, identity.username.hasPrefix("account\\"), pendingSignInData != nil else {
            throw ImouError.message("Sign in again to start verification.")
        }
        guard try result.required("captcha_id") == challenge.captchaId else {
            throw ImouError.message("The verification result does not match this sign-in.")
        }
        var data: [String: Any] = ["usage": challenge.purpose.rawValue, "captchaId": challenge.captchaId,
                                   "captchaMetaData": challenge.metadata, "isEncrypt": true,
                                   "account": try CaptchaCipher.encryptAccount(String(identity.username.dropFirst(8))),
                                   "captchaOutput": try result.required("captcha_output"),
                                   "lotNumber": try result.required("lot_number"),
                                   "passToken": try result.required("pass_token"), "genTime": try result.required("gen_time")]
        if !challenge.verifyToken.isEmpty { data["verifyToken"] = challenge.verifyToken }
        _ = try await request("common.validcode.CheckGeeTest4", data: data, verification: true,
                              apiVersion: VerificationProtocol.captchaAPIVersion)
        if challenge.purpose == .terminalCode {
            try await sendTerminalCode()
            return false
        }
        try await finishSignIn()
        return true
    }

    private func terminalAccount() throws -> (account: String, type: String, areaCode: String) {
        guard let identity, identity.username.hasPrefix("account\\"), let pendingSignInData else {
            throw ImouError.message("Sign in again to authorize this Mac.")
        }
        let account = String(identity.username.dropFirst(8))
        return (account, account.contains("@") ? "email" : "phone", pendingSignInData.string("areaCode"))
    }

    func sendTerminalCode() async throws {
        let account = try terminalAccount()
        let data: [String: Any] = ["type": account.type, "account": try CaptchaCipher.encryptAccount(account.account),
                                   "isEncrypt": true, "areaCode": account.areaCode, "usage": "GrantingCredit"]
        _ = try await request("common.validcode.GetValidCode", data: data, verification: true)
    }

    func authorizeTerminal(code: String) async throws {
        let account = try terminalAccount()
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, code.count <= 6 else { throw ImouError.message("Enter the verification code sent by Imou (up to six characters).") }
        var data: [String: Any] = ["type": account.type, "account": account.account, "validCode": code]
        if account.type == "phone" { data["areaCode"] = account.areaCode }
        _ = try await request("user.account.GrantingCredit", data: data, verification: true, apiVersion: "185612")
        try await finishSignIn()
    }

    func signOut() {
        generation = UUID()
        transport.invalidateAndCancel()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 35
        transport = URLSession(configuration: config, delegate: redirectDelegate, delegateQueue: nil)
        identity = nil
        pendingSignInData = nil
        sessionId = nil
        savedSession = nil
        host = URL(string: "https://app-v2.easy4ipcloud.com")!
        clockOffset = 0
    }

    func request(_ method: String, data: [String: Any], verification: Bool = false, apiVersion: String = "0") async throws -> [String: Any] {
        guard let identity = verification ? VerificationProtocol.identity : identity else { throw ImouError.message("Sign in to Imou first.") }
        let run = generation
        let path = "/pcs/v1/" + method
        let body = try JSONSerialization.data(withJSONObject: ["data": data], options: [.sortedKeys, .withoutEscapingSlashes])
        for attempt in 0...1 {
            try Task.checkCancellation()
            var request = URLRequest(url: host.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.httpBody = body
            request.allHTTPHeaderFields = signer.headers(path: path, body: body, identity: identity, session: sessionId,
                                                         date: PCSSigner.timestamp(Date().addingTimeInterval(clockOffset)),
                                                         nonce: String(Int64(Date().timeIntervalSince1970 * 1000)) + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), apiVersion: apiVersion)
            let (raw, response) = try await transport.data(for: request)
            try Task.checkCancellation()
            guard generation == run else { throw CancellationError() }
            guard let http = response as? HTTPURLResponse else { throw ImouError.message("Imou did not return an HTTP response.") }
            guard raw.count < 12_000_000 else { throw ImouError.message("Imou returned an oversized response.") }
            let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
            let code = Int(object.string("code"))
            if attempt == 0, [401, 412].contains(http.statusCode) || code == 11013,
               let serverTime = http.value(forHTTPHeaderField: "x-pcs-date"),
               let date = ISO8601DateFormatter().date(from: serverTime), abs(date.timeIntervalSinceNow - clockOffset) > 30 {
                clockOffset = date.timeIntervalSinceNow
                continue
            }
            return try Self.responseData(object, status: http.statusCode, method: method)
        }
        throw ImouError.message("Could not synchronize with the Imou server clock.")
    }

    static func responseData(_ object: [String: Any], status: Int, method: String) throws -> [String: Any] {
        let code = Int(object.string("code"))
        if (200...299).contains(status), code == 12112, method == "user.account.GetToken" {
            throw ImouError.terminalVerification
        }
        // Authorizing a Mac needs the account's email or phone, which a QR or saved session does not have.
        if (200...299).contains(status), code == 12112 {
            throw ImouError.message("Imou needs to authorize this Mac first. Sign in once with your email or phone and password; QR sign-in works after that.")
        }
        if (200...299).contains(status), code == 12114, ["user.account.GetToken", "common.validcode.GetValidCode"].contains(method) {
            let purpose: CaptchaPurpose = method == "common.validcode.GetValidCode" ? .terminalCode : .login
            throw ImouError.captcha(try CaptchaChallenge(data: object.object("data"), purpose: purpose))
        }
        guard (200...299).contains(status), code == 10000 else {
            let detail = object.string("errorDesc").isEmpty ? object.string("desc") : object.string("errorDesc")
            let readable = detail.isEmpty || Int(detail) != nil ? "" : " " + String(detail.prefix(200))
            throw ImouError.message("Imou rejected \(method) (HTTP \(status)\(code.map { ", code \($0)" } ?? "")).\(readable)")
        }
        if ["common.validcode.CheckGeeTest4", "common.validcode.GetValidCode", "user.account.GrantingCredit",
            "user.account.QueryLoginQRCode"].contains(method) { return object.object("data") }
        guard let data = object["data"] as? [String: Any] else {
            throw ImouError.message("Imou returned an incomplete response for \(method).")
        }
        return data
    }
}
