import CommonCrypto
import CryptoKit
import Foundation

// Mode 5 credentials come from DevicePasswordGet with a fresh request salt.
enum DeviceSecret {
    static func decodeResponse(deviceId: String, wire: String, encType: Int, salt: String) -> String? {
        guard encType == 2 else { return decode(deviceId: deviceId, wire: wire, encryptMode: 0) }
        guard !deviceId.isEmpty, !salt.isEmpty, let encrypted = Data(base64Encoded: wire),
              encrypted.count > 28 else { return nil }
        // Native device_pwd context: salt + first 16 Base64 characters of SHA256(Security-ISRC) + serial.
        let marker = Data(SHA256.hash(data: Data("Security-ISRC".utf8))).base64EncodedString().prefix(16)
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data((salt + marker + deviceId).utf8))))
        guard let box = try? AES.GCM.SealedBox(combined: encrypted),
              let clear = try? AES.GCM.open(box, using: key),
              let plain = String(data: clear, encoding: .utf8), !plain.isEmpty,
              !plain.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return plain
    }

    static func decode(deviceId: String, wire: String, encryptMode: Int) -> String? {
        guard encryptMode != 5, !deviceId.isEmpty, let encrypted = Data(base64Encoded: wire),
              !encrypted.isEmpty, encrypted.count % kCCBlockSizeAES128 == 0 else { return nil }
        let key = Data(PCSIdentity.md5(Data((deviceId.uppercased() + "DAHUAKEY").utf8)).utf8)
        let iv = Data("0a52uuEvqlOLc5TO".utf8)
        var result = Data(count: encrypted.count + kCCBlockSizeAES128)
        var length = 0
        let capacity = result.count
        let status = result.withUnsafeMutableBytes { output in
            encrypted.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                input.baseAddress, encrypted.count, output.baseAddress, capacity, &length)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        result.count = length
        guard let plain = String(data: result, encoding: .utf8), !plain.isEmpty,
              !plain.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return plain
    }
}
