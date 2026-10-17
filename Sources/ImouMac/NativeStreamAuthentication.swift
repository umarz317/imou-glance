import CryptoKit
import Foundation

enum NativeStreamAuthentication {
    static func request(resource: String, username: String, date: Date = Date(),
                        nonce: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()) throws -> URLRequest {
        guard !username.isEmpty, !username.contains(where: { $0 == "\"" || $0 == "\\" }),
              !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              nonce.count == 32, nonce.allSatisfy({ $0.isHexDigit }) else {
            throw ImouError.message("Imou did not provide a usable camera login name.")
        }
        let url = try DirectStream.nativeResource(resource)
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ImouError.message("Imou returned an invalid camera request.")
        }
        let query = parts.percentEncodedQuery ?? ""
        guard !query.split(separator: "&").contains(where: { $0.split(separator: "=", maxSplits: 1).first == "method" }) else {
            throw ImouError.message("Imou returned an unexpected camera control request.")
        }
        let target = parts.percentEncodedPath + (query.isEmpty ? "?" : "?" + query + "&") + "method=0"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let created = formatter.string(from: date)
        // Native remote UsernameTokenV2 uses this raw SHA256 key and an empty GET content field.
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data((username + ":Login to ").utf8))))
        let digest = Data(HMAC<SHA256>.authenticationCode(for: Data((target + nonce + created).utf8), using: key)).base64EncodedString()
        var final = parts
        final.percentEncodedQuery = (query.isEmpty ? "" : query + "&") + "method=0"
        guard let finalURL = final.url else { throw ImouError.message("Could not prepare the camera request.") }
        var request = URLRequest(url: finalURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue("WSSE profile=\"UsernameTokenV2\"", forHTTPHeaderField: "Authorization")
        request.setValue("UsernameToken Username=\"\(username)\", PasswordDigest=\"\(digest)\", Nonce=\"\(nonce)\", Created=\"\(created)\"", forHTTPHeaderField: "WSSE")
        request.setValue("Http Stream Client/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        request.setValue("1", forHTTPHeaderField: "Cseq")
        request.setValue("Private", forHTTPHeaderField: "Accpet-Sdp")
        return request
    }
}
