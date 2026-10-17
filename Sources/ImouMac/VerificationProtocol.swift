import Foundation

// Windows LCBaseLogic OnRequestGetValidCode service identity; provenance in analysis/verification-service-identity.json.
// Default principals skip the account layer's prehash; RestApi hashes this credential once.
enum VerificationProtocol {
    // Modern LCRequest::setHeader, used by LCGeeTest's pre-login postAuto request.
    static let captchaAPIVersion = "3.10.0"

    static let identity: PCSIdentity = {
        let credential = "%^k#1DI2gI#hdNK%eb#JPk@nJIxGXV1U"
        return PCSIdentity(username: "default\\2QnTkhG3^t!rKXNP",
                           md5Key: PCSIdentity.md5(Data(credential.utf8)),
                           sha256Key: PCSIdentity.sha256(Data(credential.utf8)))
    }()
}
