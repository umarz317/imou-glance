import CryptoKit
import Foundation

// LCCommon's account wrapper: SHA256(protocol key + ENCRYPTKEY), then Base64(nonce|ciphertext|tag).
enum CaptchaCipher {
    static func encryptAccount(_ account: String, nonce: AES.GCM.Nonce? = nil) throws -> String {
        guard !account.isEmpty, account.utf8.count <= 320 else {
            throw ImouError.message("Imou returned an invalid account for verification.")
        }
        let material = Data("F9TtRyv7X89nM0vp2EKOjdKLFnjlrN9rENCRYPTKEY".utf8)
        let key = SymmetricKey(data: Data(SHA256.hash(data: material)))
        let sealed = try AES.GCM.seal(Data(account.utf8), using: key, nonce: nonce)
        guard let combined = sealed.combined else { throw ImouError.message("Could not prepare Imou verification.") }
        return combined.base64EncodedString()
    }
}
