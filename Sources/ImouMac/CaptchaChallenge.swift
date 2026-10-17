import Foundation

enum CaptchaPurpose: String { case login = "Login", terminalCode = "GrantingCredit" }

struct CaptchaChallenge: Identifiable {
    let id = UUID()
    let captchaId: String
    let verifyToken: String
    let metadata: String
    let purpose: CaptchaPurpose

    init(data: [String: Any], purpose: CaptchaPurpose = .login) throws {
        self.purpose = purpose
        let captcha = data.object("captchaData")
        captchaId = try captcha.required("captchaId")
        verifyToken = captcha.string("verifyToken")
        metadata = data.string("captchaMetaData")
        guard captchaId.count <= 256, verifyToken.utf8.count <= 16_384, metadata.utf8.count <= 65_536 else {
            throw ImouError.message("Imou returned an invalid verification challenge.")
        }
    }
}
