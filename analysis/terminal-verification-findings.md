# Consumer terminal verification (12112 / native 29)

Static evidence only. No account request, code send, email, SMS, or verification submission was performed by this worker. The user must request a code and enter the code they receive; this flow does not bypass verification.

## Observed Windows flow

The native-UI worker established that GetToken API code `12112` becomes native result `29`, whose existing-account dialog uses terminal-binding-required text. It presents a six-character verification-code entry. For an overseas email account, the send-code helper selects:

- `type`: string `email`.
- `usage`: string `GrantingCredit`.
- `areaCode`: empty string.
- `account`: the original account from the login UI.

UI source anchors supplied by native-UI worker: EXE send helper VA `0x1401f8d50`, usage switch at `0x1401f8dbc`, overseas email detection at `0x1401f8eed`, submit helper `0x1401f92e0`, final `GrantingCredit` virtual call at `0x1401f9560`. Virtual mapping was corroborated against LCBaseLogic UserManager vtable entries: GetValidCode thunk at VA `0x18038f108`, GrantingCredit thunk at `0x18038f120`, matching UI virtual offsets `+0x68` and `+0x80`.

## Send code: actual modern LCBaseLogic caller

Binary `analysis/installer/bin/LCBaseLogic.dll`, SHA-256 `2c75495f9a8898338105f484f1deb922d8fa694c7a831f20377282b16f638b24`.

Export `OnRequestGetValidCode` thunk `0x1800050fb` jumps to actual VA `0x180230ee0`–`0x180231ea5`. Complete annotated instructions saved `analysis/validcode-caller-annotated.asm`.

The modern caller sends `/pcs/v1/common.validcode.GetValidCode` using direct-URI request construction, with JSON root `data` and:

- `type`: original type string.
- `account`: GCM-encrypted original account string.
- `isEncrypt`: JSON boolean `true`.
- `areaCode`: original area-code string, empty for email.
- `usage`: original usage string, `GrantingCredit` for this flow.
- `accessToken`: included only when supplied/nonempty by the caller.

Do not substitute the old generated GetValidCode schema's API version for this direct-URI caller. The root investigation established direct-URI requests use API version 0.

### GCM parity

At VA `0x1802315cd`, caller loads the same protocol key used by `CaptchaCipher`. It passes context `base` to GCM helper thunk `0x180001794`, actual `0x180314320`, at `0x180231776`. This helper treats `open_body` specially; other contexts use key derivation `0x1803153d0`. That derivation only distinguishes `file_upload` and `device_pwd`; its default path appends `ENCRYPTKEY` at `0x18031565b` before SHA-256. Thus context `base` uses the same key/nonce-ciphertext-tag account format as the existing CAPTCHA account wrapper. Evidence saved in `analysis/verification-gcm-annotated.asm` and `analysis/verification-gcm-key-annotated.asm`.

### Service identity

If the public wrapper's auth-reset flag is enabled, the native caller configures client 1 with the shipped verification service principal/credential before sending. UI existing-account flow explicitly requests this reset: EXE instruction `0x1401f9074` sets stack `+0x28` to true immediately before GetValidCode call `0x1401f90ae`. Stack `+0x20` is usage and `+0x30` is optional extra accessToken (normally empty). The separate helper flag selecting usage GrantingCredit is not this auth-reset flag.

The protocol identity and final MD5/SHA256 PCS signer keys are saved in `analysis/verification-service-identity.json`, with derivation and source hash. These are application protocol constants from the supplied binary, not user credentials. `Sources/ImouMac/VerificationProtocol.swift` exposes only `VerificationProtocol.identity`, implemented at the root worker's explicit request.

Offline derivation corroboration:

1. `AesDecryptLoginInfo` actual VA `0x1802420a0` calls `GetDKeyString`, actual `0x1802e7ab0`.
2. `GetDKeyString` Base64-decodes `REFIVUFLRVk=` to `DAHUAKEY`.
3. AES key is the ASCII lowercase MD5 hex of that string; IV is `0a52uuEvqlOLc5TO`; encrypted protocol literals are Base64 AES-256-CBC with PKCS7 padding.
4. Both protocol literals decrypt cleanly offline.
5. Default principal skips account-prefix preprocessing in `SetRestClientAuthEx`; `hsview_client_set_authEx` then hashes its credential once for each PCS signing key. It must not use the account login identity's double-hash constructor.

Instruction evidence: `analysis/service-key-annotated.asm`, `analysis/service-credential-decrypt-annotated.asm`; preexisting helper pseudocode `analysis/auth-pseudocode.c`, `analysis/direct-authset.c`.

Implement service identity as a per-request override. Preserve the user's pending account-derived identity for subsequent GetToken retries. Use the same terminal ID/UA throughout the authorized verification attempt.

## Submit code: GrantingCredit

Native LCBaseLogic actual VA `0x180232900`–`0x180232d2c` is reached from export thunk `0x1800056aa`. Annotated evidence: `analysis/credit-caller-annotated.asm`.

It uses the generated `user.account.GrantingCredit` request builder and copies:

```text
data.validCode = user-entered code string
data.type = "email" for overseas email account
data.account = original account string
```

`areaCode` is included only for type `phone`; the comparison is at `0x180232b02`, and conditional field assignment at `0x180232bd0`. The caller does not encrypt the account or set `isEncrypt` on this request. Do not copy the send-code body's account encryption into GrantingCredit.

It obtains client 1 with `GetClientHandle(1,false)` at `0x180232c05`, performs no auth reset, and calls SendRequest at `0x180232c4a`. Therefore the normal send-code → submit-code sequence reuses service authentication configured by the send step. This is an observed ordering dependency of the native implementation, not an instruction to mutate our entire app's account identity.

### API version and result

`RestApimd.dll` SHA-256 `7aff27e0199c3182f1d630e7d95bc0084b787918f9014d4a968d7d27e185981f`.

GrantingCredit builder VA `0x1800e7860` writes API version `185612` to request offset `+0x38`. Native caller does not overwrite it. The normal SaaS signer reads this field both into canonical `x-pcs-apiver` and outgoing header. **Use API version 185612 for this generated endpoint**, not hardcoded 0.

Request schema fields are strings `validCode`, `type`, `areaCode`, `account`. Evidence `ev_2ed541a1a57bc7cb88928b4e0ff0318c2f4cf2210b93f11229384c3075295338`, files `analysis/terminal-credit-request.{json,c}`.

GrantingCredit and GetValidCode share generic no-data response implementation at VA `0x1800ddbe0` (dummy integer `_nouse`). Native caller stores SendRequest's return status in the event, and the UI owns the success/retry transition. No credential, token, or account record is returned by this response schema. Evidence `ev_77863f9165484c4e759660970249ec22dd4f0ad3bc7835061a4e9fbe38463475`, files `analysis/terminal-no-data-response.{json,c}`.

## Adjacent APIs, not required substitutions

- `GetTwoStepVerifyState`: request `account` string, API version `57205`; response strings `state`, `areaCode`, `account`. Response Evidence `ev_21b97725e0d54692c9e34b862967acc9194a75b42fac6b3e9bf2088a72ccd968`, files `analysis/terminal-two-step-response.{json,c}`. Its existence does not establish that status29 requires calling it.
- Legacy generated GetValidCode schema: string fields `type`, `areaCode`, `usage`, `accessToken`, `account`, API version `61452`. The current modern direct-URI caller above adds account encryption and must take precedence. Evidence `ev_5e67cf669154b93552667bc0bd0b2692c8a0d06eb02c215e12be2a1d2438783f`, files `analysis/terminal-send-code-request.{json,c}`.
- `BindPhone`: strings `phone`, `validCode`, `email`, API version `89701`. It belongs to the separate phone-binding branch and should not replace ordinary existing-email `GrantingCredit`. Evidence `ev_d65e1a5ecabe1b0a3b95587606a68fb5718fe98f4e730a419c85165e6353339c`, files `analysis/terminal-bind-phone-request.{json,c}`.

## Validation limits

Shared REA snapshot `analysis/terminal-verify-rest-snapshot.json` retains complete REST evidence and was closed successfully. Static service constants were decrypted offline; the source file passes `swiftc -frontend -parse`. No successful code send, code submission, terminal binding, or post-verification login has been validated. The root worker owns integration, UI behavior, full build/tests, and authorized runtime validation.
