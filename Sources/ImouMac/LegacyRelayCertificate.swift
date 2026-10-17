import CryptoKit
import Foundation
import Security

enum LegacyRelayCertificate {
    // Exact expired leaf observed on the Imou-supplied relay; never accept arbitrary certificates.
    static let fingerprint = "F7B3D7133FFD45B44B61B4C5B22192AE2A9FE4C346EA941308C656FE698BBBF2"
    @MainActor static var approvedForRun = false

    static func fingerprint(in trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let data = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    static func permits(_ candidate: String?, approved: Bool) -> Bool {
        approved && candidate == fingerprint
    }
}
