# QR-code sign-in

Static findings from the Windows client (llvm-objdump; no Ghidra/Hopper). Not yet validated against Imou at runtime.

## Why QR instead of Sign in with Apple

Imou's iPad app (`com.imoulife.pad`, team `842F5V5MV9`) signs in with Apple through `user.account.ThirdAccountAuth`
(`identityToken`, `authCode`). An Apple identity token is bound to the requesting app (`aud`) and its user id (`sub`) is
per developer team, so a token minted for Imou Glance cannot sign in to an existing Imou account. The Windows client has no
Apple login at all; it offers password, SMS and QR login. QR login works for any account, including Apple-linked ones,
because the phone app that is already signed in approves the Mac.

## Protocol

Both calls are signed with the pre-login service identity (`default\…`, same AES-decrypted literals as
`OnRequestGetValidCode`, see `verification-service-identity.json`).

| Step | Method | API version | Request | Response |
| --- | --- | --- | --- | --- |
| Show code | `user.account.GetLoginQRCode` | `138591` | `width`, `height` (int) | `loginCode`, `QRCodeImage` |
| Poll | `user.account.QueryLoginQRCode` | `0` (direct URI, like GetValidCode) | `loginCode` | `status`, `username`, `token`, `sessionId`, `userId`, `entryUrlV2`, `nickname`, `avatarUrl`, `bindEmail`, `bindPhone`, `supportPcAutoLogin` |
| Phone | `user.account.UpdateLoginQRCode` | `87068` | `loginCode`, `status` | (phone side, not used by the Mac) |

Evidence (`RestApimd.dll` SHA-256 `7aff27e0…981f`, `LCBaseLogic.dll`):

- `hsview_api_init_userAccount_GetLoginQRCodeRequest` `0x1800e6b30`: members `height`, `width`; version string `138591`.
- `hsview_api_init_userAccount_GetLoginQRCodeResponse` `0x1800e6c50`: members `loginCode`, `QRCodeImage`.
- `hsview_api_init_userAccount_QueryLoginQRCodeResponse` `0x1800e7fe0`: members listed above.
- `UserManager::OnRequestGetLoginORCode` `0x18023b900`: `SetRestClientAuthEx` with the `default\` identity, then `SendRequest`.
- `UserManager::OnRequestQueryLoginORCode` (`0x18023c3e9` onward): same identity, `SendRequestWithUri("/pcs/v1/user.account.QueryLoginQRCode")`,
  body `{"data":{"loginCode":…}}`; compares `status` with `login`, `cancel`, `expire`.

## Live checks (18 October 2026)

- Scan and approve on the phone signed in and loaded cameras.
- Unscanned code (`Tests/ImouMacTests/LiveLoginQRCodeProbe.swift`): `QRCodeImage` is Base64 PNG (776 bytes at 360 px);
  `QueryLoginQRCode` returns code 10000 with `{"status":"unscan"}` until about 307 s, then `{"status":"expire"}`.

## Unknowns

- Statuses between scan and approval, and the `cancel` path when declined on the phone.
- Whether a QR sign-in can trigger terminal authorization (code 12112); not observed in the Query handler. The app
  reports it with a password-sign-in hint, because GrantingCredit needs the account's email or phone.
- How long a saved QR session stays valid; a session Imou rejects is deleted on the next launch.

Implementation: `ImouClient.loginQRCode` / `pollLoginQRCode`, `PreviewModel.signInWithQRCode`.
