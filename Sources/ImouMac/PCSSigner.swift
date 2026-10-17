import CryptoKit
import Foundation

struct PCSIdentity {
    let username: String
    let md5Key: String
    let sha256Key: String

    static func account(_ account: String, password: String) -> Self {
        // The account layer hashes first; RestApi hashes the resulting hex string again.
        Self(username: "account\\" + account,
             md5Key: md5(Data(md5(Data(password.utf8)).utf8)),
             sha256Key: sha256(Data(sha256(Data(password.utf8)).utf8)))
    }

    static func token(_ username: String, token: String) -> Self {
        Self(username: "uuid\\" + username, md5Key: md5(Data(token.utf8)), sha256Key: sha256(Data(token.utf8)))
    }

    static func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

struct PCSSigner {
    let userAgent: String

    static func canonical(path: String, digest: String, userAgent: String, date: String,
                          nonce: String, username: String, session: String?, apiVersion: String = "0") -> String {
        "POST\n\(path)\n\(digest)\napplication/json\nx-pcs-apiver:\(apiVersion)\nx-pcs-client-ua:\(userAgent)\nx-pcs-date:\(date)\nx-pcs-nonce:\(nonce)\n"
        + (session.map { "x-pcs-session-id:\($0)\n" } ?? "")
        + "x-pcs-username:\(username)\n"
    }

    func headers(path: String, body: Data, identity: PCSIdentity, session: String?,
                 date: String, nonce: String, apiVersion: String = "0") -> [String: String] {
        let md5 = Data(Insecure.MD5.hash(data: body)).base64EncodedString()
        let sha = Data(SHA256.hash(data: body)).base64EncodedString()
        func signature(_ digest: String, key: String) -> String {
            let message = Self.canonical(path: path, digest: digest, userAgent: userAgent, date: date,
                                         nonce: nonce, username: identity.username, session: session, apiVersion: apiVersion)
            return Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(key.utf8)))).base64EncodedString()
        }
        var result = ["Content-Type": "application/json", "Content-MD5": md5, "Content-SHA256": sha,
                      "x-pcs-apiver": apiVersion, "x-pcs-client-ua": userAgent, "x-pcs-date": date,
                      "x-pcs-nonce": nonce, "x-pcs-username": identity.username,
                      "x-pcs-signature": signature(md5, key: identity.md5Key),
                      "x-pcs-signature-sha256": signature(sha, key: identity.sha256Key)]
        result["x-pcs-session-id"] = session
        return result
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: date)
    }
}

enum ImouError: LocalizedError {
    case message(String)
    case captcha(CaptchaChallenge)
    case terminalVerification
    /// A camera setup the app cannot play; retrying will not help.
    case unsupported(String)
    var errorDescription: String? {
        switch self {
        case let .message(text), let .unsupported(text): return text
        case .captcha: return "Complete Imou’s verification challenge to continue signing in."
        case .terminalVerification: return "Imou requires a verification code to authorize this Mac."
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String {
        if let string = self[key] as? String { return string }
        if let number = self[key] as? NSNumber { return number.stringValue }
        return ""
    }
    func object(_ key: String) -> [String: Any] { self[key] as? [String: Any] ?? [:] }
    func objects(_ key: String) -> [[String: Any]] { self[key] as? [[String: Any]] ?? [] }
    func required(_ key: String) throws -> String {
        let value = string(key)
        guard !value.isEmpty else { throw ImouError.message("Imou returned an incomplete response (\(key)).") }
        return value
    }
}
