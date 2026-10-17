# Direct Imou menu bar client

This replaces the earlier ScreenCaptureKit companion. The running app contains no window-capture or iPad-launch path. The earlier app artifact is preserved under ignored `build/previous-mirror/`.

## Implemented path

1. Native SwiftUI MenuBarExtra, window-style popover, secure password field and camera picker.
2. PCS requests signed in Swift with CryptoKit: exact LF canonicalization, Base64 body digests, credential-derived HMAC-SHA256, unique nonce, UTC date and session header. Account passwords use the two hashing layers recovered from LCBaseLogic and RestApi; UUID/token requests hash the returned token once. MD5 is required for this existing protocol, not introduced as local password storage.
3. `user.account.GetToken`, then UUID/token `user.account.Login`, with HTTPS regional host validation. PCS success code is 10000; a successful envelope can still report failed credentials through `data.failNum`. No blind password retries. A single date-correction retry is allowed only for a clock challenge with a meaningful offset.
4. `device.list.BasicPageGet` paginated by binding ID, followed by `CommonInfoGetByIds`. Device/channel media configuration is retained in memory. JSON-string `mediaConfig` is parsed explicitly.
5. Legacy wire camera passwords are Base64/AES-256-CBC/PKCS7 decoded with the recovered per-device formula. Newer credentials are retrieved with `iot.control.DevicePasswordGet`, using a fresh 16-character salt and the current account session. Type-2 responses use the recovered AES-256-GCM derivation. Camera keys remain in memory and are cleared on sign-out; the normal UI does not request a manually entered safety code. A complete playback-token pair can provide the player's credentials directly.
6. `things.media.GetRealTransferStreamUrl`, selecting advertised RTSV and the returned `tls_resource`. Native encryption mode 1 translates to RTSV encryption mode 2. No `skipAuth` request is sent. Single view uses windowNum string "1", first design/audioType0, and reported clarity/stream/image-size values.
7. Native HTTPS media transport using the recovered remote WSSE V2 request, with system certificate validation and no redirects. Private XAV framing or private DHAV-in-RTP is removed in Swift. The locally bundled official decoder runs in ephemeral WKWebView. Five fixed public asset routes are served on 127.0.0.1; camera configuration and video payloads use argument-based JavaScript evaluation, not local HTTP. Media authentication headers are excluded from the renderer configuration. Vendor diagnostics are disabled. Live is reported only after decoded-frame metadata.
8. Hide/close/sign-out tears down the player; reopening negotiates a new stream URL. Password/session/device data are never intentionally persisted or logged. A nonsecret terminal ID is persisted for client identity.

## REA evidence

Original Windows installer: SHA-256 `052c73d953b04329e2027cabaf676668babbc49d5b5ea38f5679e889bd6b720d`.

RestApimd.dll: SHA-256 `7aff27e0199c3182f1d630e7d95bc0084b787918f9014d4a968d7d27e185981f`.

| Claim | REA Evidence ID |
| --- | --- |
| GetToken body and returned token/session/username | ev_2f34b05bcad6b4de5073baf003bdc79d1b11523c02e95193db2e52feea472416 |
| Account-prefix prehash logic | ev_594368b77e1c0fba2cf1a7f7fb9cda8f40efadecb8456c83815b24ac643f9f40 |
| RestApi credential hashing | ev_0c5fd2868060c4ed3e7ab4c56df9817995f1db275ddff7a167efa5897020e70b |
| Request signer | ev_a18d0f81b8bdbe7bb634413288a6dd2003482d60b0f19257ba95242e0a90c46c |
| Request signer readable projection | ev_637fd7d1e78e3f62770573d43666050adc8ba03e4861dfba51d4968d7878b354 |
| Server-clock retry | ev_797aa22437a2edeae38555ba4fbe93cba69acad8c2430f8fda9b7d97ebc9ba66 |
| Basic camera pagination | ev_897cc5525b91016bc371b172a69250b783a91c97be98659cc6704e35dcca411a |
| Camera detail request | ev_a5b21849edc048257f2207babcd2f82529a13012074bc8dc0c2ca663e0a8798c |
| Legacy camera AES decoding | ev_16b41fd1a4faee4efe1a93ff0e5cfd06fd615c90e2f8501088cdeeb5ad77a29f |
| Full stream negotiation | ev_8b94fc1e7f8299e35f5b32ce7d20e4264a0acf4340e9563a430a3ef3734cf6e8 |

Static pseudocode is reconstructed behavior, not proof that the server accepts a request. Complete RestApi evidence and a replay snapshot were exported locally before closing its REA session. Raw bundles, installer files and large analysis outputs are ignored by Git. Other independent sessions have also closed.

## Validation and remaining gaps

Verified: release build and ad hoc signature; native sign-in UI; independent synthetic signer vectors; token/session canonicalization; host validation; encoded media parsing; an OpenSSL-derived legacy AES fixture and invalid-input handling. The isolated WebKit harness initializes the actual bundled main WASM and single-thread decoder worker, serves correct fixed routes/MIME types, and shuts down.

Three diagnostic requests used unique nonexistent `example.invalid` accounts only. macOS and Windows client labels both produced HTTP200/code10000; the app-shaped terminal ID/nonce request returned `data.failNum:1`. This establishes envelope/error handling, not successful authentication. An initial real native sign-in displayed HTTP200/code11001; its exact cause remains under investigation. No user password was read from another app, copied into chat, or logged.

User-validated since the original checks: successful real consumer-account sign-in, trusted-terminal authorization and camera discovery. Remaining gaps: complete device response compatibility, automatic retrieval of newer camera passwords, media relay authorization/decryption and a changing camera frame. Mode 1/MIKEY is rejected by the embedded player; RTSV mode translation avoids it when advertised. Unsupported transport/encryption and missing device codes are explicit errors, never silent cleartext fallbacks.

The current implementation is a standalone build for validation, not a claim of completed end-to-end camera access.

## Authentication follow-up, 2026-10-17

The updated native email sign-in reached GetToken HTTP200/code12114. Static Windows UI evidence maps this to native35 and an LCGeeTest CAPTCHA screen. It is not classified as a wrong password or a trusted-terminal challenge. Implementing its normal human-completed CAPTCHA flow is now required before the account session can be validated. No CAPTCHA solution or token is fabricated, and no real-account retry is automatic.

The CAPTCHA branch is implemented with an ephemeral official GeeTest v4 widget. Only its public captchaId reaches that page. The result is checked against the active challenge and submitted through `common.validcode.CheckGeeTest4` with the original captchaMetaData/verifyToken, usage `Login`, the five vendor result fields and `isEncrypt:true`. Its account wrapper follows recovered LCCommon behavior: SHA256 of the protocol key plus `ENCRYPTKEY`, AES-256-GCM, Base64 of 12-byte nonce + ciphertext + 16-byte tag, no AAD. The native result callback does not install an invented ticket header; success permits the same pending GetToken operation to run again.

Eight unit tests now pass, including an independent Node AES-GCM vector, challenge extraction, strict PCS success handling and prior signer/AES fixtures. A separate real WebKit harness loaded the official gt4.js and verified initGeetest4 availability without initializing or solving a challenge. Human CAPTCHA completion, server validation, account success and live video remain unverified.

The first CAPTCHA-enabled app attempt again returned GetToken code11001 before a challenge could load. Digest casing and the shipped dual-signature default were independently reconfirmed from original PE instructions. The latest build uses Windows PC protocol metadata for compatibility with the recovered consumer AppID; the terminal is still named Imou Peek for Mac. This metadata adjustment is a compatibility hypothesis, not a proven resolution of11001. Native errors now display the server's short error description when supplied. The local CAPTCHA document uses the same pc.imoulife.com page origin as the native client; passwords and account challenge secrets remain outside the webview.

## Terminal binding follow-up, 2026-10-17

The PC-profile build reached real GetToken code12112. DealResultRet maps it to native29, whose Windows form explicitly explains that terminal binding is enabled and requires a verification code to the registered account. The send button is user-operated; opening the form does not send a message.

The app now presents Authorize this Mac and preserves its pending account-derived signing keys in memory. Send Verification Code uses common.validcode.GetValidCode, API0, type email, usage GrantingCredit, an empty email areaCode and the recovered AES-GCM account wrapper with isEncrypt true. That specific Windows UI sets resetAuth true; the code request uses the shipped default service identity, independently recovered from the supplied binary. It never uses a developer account or another app's session.

User-entered confirmation is submitted as user.account.GrantingCredit with API185612, the same service identity, raw account over HTTPS, type email and validCode; areaCode is omitted for email. The account identity remains separate. On verified success the original account GetToken/Login sequence resumes, matching the Windows success callback without inventing a ticket header. A CAPTCHA on the send-code request preserves purpose GrantingCredit and resumes only the pending code-send action after human completion. A local 60-second resend cooldown avoids repeated sends.

Eleven protocol tests pass, including a Python-derived API185612 HMAC fixture, terminal-binding response classification and CAPTCHA continuation purpose. This is offline verification. No code-send or authorization request has been performed by the assistant; the user must operate those buttons in the native app. Live account and video success remain unverified. Full evidence: analysis/terminal-verification-findings.md and the updated analysis/pcs-config.md. REA sessions are closed.

## Camera-key follow-up, 2026-10-17

The user completed terminal authorization in the native app and reported that cameras appear. They then encountered the safety-code requirement and confirmed that the official app does not require manual entry. The current legacy-only list-password decoder is insufficient for that behavior: automatic camera-key retrieval is a required implementation gap, not an established need for the user to supply a label code. Focused REA work is tracing `iot.control.DevicePasswordGet` and its GCM response handling. Live playback has not yet been validated.

The follow-up implements that request using the existing UUID/token session, API version 0, string channel ID and a fresh 16-character alphanumeric salt. Its response's `encType` controls decoding: type 2 uses AES-256-GCM with `SHA256(salt + Base64(SHA256("Security-ISRC")).prefix(16) + deviceId)`, and Base64(nonce12|ciphertext|tag16); other native wire types use the legacy decoder. The same request salt is retained in memory for response authentication. A complete returned playback-token pair is also accepted. The player receives the automatic password through its existing device-login fields with empty manual `code`, avoiding the vendor's manual override query mutation. Encrypted deviceUsername uses the verified legacy decoder; missing usernames are not guessed.

Fourteen tests pass, including an independent Node GCM fixture, wrong serial/salt, tampered tag and invalid plaintext checks. An actual isolated WKWebView test initialized the pinned vendor worker and verified automatic credential plumbing plus mode-5 WASM derivation, without camera transport. The safety-code field has been removed from the normal camera view. Source evidence: `analysis/automatic-device-credentials.md`, the automatic-password section in `analysis/pcs-config.md`, and `analysis/direct-media-research.md`. Successful live camera decryption remains unverified.

## Secure resource format follow-up, 2026-10-17

The user reported another connection error. Native accessibility inspection showed `Imou returned an unsupported secure stream resource.` Thus stream negotiation returned a nonempty `tls_resource`, but the app rejected its format before password retrieval/player startup. The exact URL and scheme were not logged or inspected.

Independent original-byte analysis confirmed native parsers accept both `rtsp://` and `rtsps://`, stripping only their respective 7/8-character prefixes before shared authority/path parsing. The selected TLS resource and native TLS flag are separate from this carrier syntax. The pinned JavaScript decoder, however, only strips `rtsp://`. The app now accepts both formats from `tls_resource` and adapts only `rtsps` to the browser's `rtsp` carrier; existing WSS enforcement remains in place. Server, explicit port, encoded path and query are preserved byte-for-byte. Other schemes remain rejected, with only a redacted scheme category shown for diagnosis. Sixteen tests pass, including preservation and rejection fixtures. Evidence: `analysis/secure-stream-resource.md`. Whether this resolves the user's actual resource format remains unverified until the next native attempt.

## Native media transport follow-up, 2026-10-17

The next native attempt still failed resource validation. Accessibility inspection showed the updated `(missing scheme)` category. A read-only debugger inspection of this project's running app then established format metadata only: the TLS resource is a bare authority with explicit port, followed by `/live/realmonitor.rtpxav` and an opaque query. No address, query values, credentials or camera keys were printed or saved. The debugger was detached and the app resumed. Native `createHttpCamera` independently confirms that bare format, with TLS configured separately.

The official web player's RTSV adapter is incompatible with this consumer URL: its synthetic test drops the second path component and query, sends a fixed `.xav` request, and omits HTTP authentication. The implementation therefore uses native HTTPS for the original resource, not a guessed prefix fix or endpoint rewrite. It appends the Windows client's ordinary `method=0`, signs that exact target with remote WSSE UsernameTokenV2, and retains system certificate verification. Device-login identity is recovered from the account's encrypted deviceUsername. WSSE request headers remain outside the renderer's Codable configuration; the ephemeral transport does not use a cookie jar or credential store, and refuses redirects.

Response Content-Type selects the framing. Private XAV uses `$`, channel and a BE32 length. RTP-private uses `$`, channel and a BE16 length, followed by RTP. The latter removes variable RTP headers, CSRCs, extensions and padding; it accepts video only after a DHAV header with valid size/checksum, locks payload type and SSRC, and rejects sequence gaps/source changes instead of joining unrelated video. Other codecs remain unsupported. Payload delivery is ordered, limited to 5 MiB per packet and a 16 MiB queue, and stops with visibility/session teardown. The original relay path/query is preserved; no `.rtpxav` to `.xav` substitution is implemented.

Twenty-two tests pass, including independent WSSE HMAC fixtures, encoded target preservation, renderer/header separation, RTP fragmentation/extension/padding/control handling, private-header damage and stream continuity. The real pinned WASM parsed 37 synthetic DHAV frames under six input chunk sizes, down to one byte. An isolated actual WKWebView test confirmed native start/open/packet/stop bridging and stale-session rejection without making any media request. Those are offline/runtime-component checks, not proof of an authorized camera frame. The rebuilt native transport still needs a real account/camera attempt.

Evidence: `analysis/native-http-media-protocol.md`, `analysis/native-http-credentials-and-rtp.md`, `analysis/vendor-dhav-header.md`, `analysis/secure-stream-resource.md`, and `analysis/direct-media-research.md`. All worker analysis sessions/processes are closed.

## Relay certificate follow-up, 2026-10-17

The user's native attempt failed with URLSession -1200. A bounded debugger inspection of this project's own running app found stream error -9802 and SecTrust -67602. Trust result detail keys identify SSLHostname and TemporalValidity failures on the leaf, plus TemporalValidity on the intermediate. The leaf was valid from 2018-02-07 to 2020-03-20; the intermediate expired in 2024. Only numeric diagnostics, validity dates and public certificate hashes were read; no media address, URL query, password or key was printed. The debugger was detached and the app resumed.

Observed DER SHA-256 chain: leaf `F7B3D7133FFD45B44B61B4C5B22192AE2A9FE4C346EA941308C656FE698BBBF2`, intermediate `BFDF4CF3F143AD0DB912D8AB3A7C12F617B9EA60CE8B1F4E44F74270FB21B19B`, root `EBD41040E4BB3EC742C9E381D31EF2A41A48B6685C96E7CEF3C1DF6CD4331C99`.

Independent native analysis confirms that the default Windows media socket leaves peer verification disabled. Its bundled CA files serve other known clients; adding them would not fix the observed expiry or hostname mismatch. No verified DNS mapping or alternative certificate identity was found in the bounded response-parser and media-factory analysis. RTSP negotiation exists but is not proof of another valid relay. See `analysis/native-media-tls.md`, `analysis/native-tls-public-ca.md` and the public CA fingerprint inventory.

The compatibility option defaults off. After the known certificate fails, the UI offers Review Relay Certificate and explains its expiry, hostname mismatch, exact SHA-256 and impersonation risk. Only a user-operated confirmation enables acceptance. The exception permits exactly the observed leaf DER hash, only on the active native HTTPS session at its original host and port. It clears on sign-out/quit and does not modify account API validation or macOS trust. Other certificates receive normal system validation. No compatibility approval or live video success has been claimed.

The same change fixes visibility bookkeeping when the menu popover and inspection window coexist, and preserves native transport errors against later generic decoder status callbacks. Twenty-six tests pass, including default rejection, exact certificate matching, approval reset, numeric error redaction and preview visibility. A fresh real-account attempt and explicit user certificate decision remain necessary.

## ATS and approval UI follow-up, 2026-10-17

The user confirmed allowing the old exception still produced the same error. Runtime inspection verified approval=true, the trust acceptance branch executing, URLSession -1200 / TLS -9802, and redacted OS diagnostics reporting `ATS failed system trust`. Therefore the original URLSession delegate exception was ineffective under ATS. The approved media path now uses Network.framework TLS with the same exact leaf pin and a TLS 1.2 minimum; strict/default requests and all account requests retain URLSession/ATS. A bounded HTTP/1 parser preserves the signed request and supplies private-media payloads to the existing framer.

Independent review also found a stale confirmation could restore approval after sign-out. Review IDs now belong to the signed-in account generation. The user encountered an unclickable native alert in the menu popover; review and confirmation are now inline, without a modal sheet. Thirty-eight tests passed at this stage and the release build verified its signature. Detailed runtime evidence, downloaded IPA identity, REA encryption findings, and limitations are in `analysis/relay-ats-follow-up.md`.

## Private SDP prefix follow-up, 2026-10-17

After the user approved the current session, runtime inspection confirmed HTTP 200 and RTP/DHAV bytes. The response declares `Private-Length: 583` and `Private-Type: application/sdp`; its first body bytes are that SDP, followed by interleaved RTP. The media framer incorrectly assumed the HTTP body began with `$`. Both native transport paths now pass through Private-Length and consume precisely that bounded prefix before framing media. Windows native evidence independently confirms the separation; see `analysis/native-sdp-framing.md`. All 40 Swift tests pass, including every two-chunk split of synthetic HTTP/SDP/RTP and HTTP/SDP/XAV streams. Actual decoded, changing camera frames remain unconfirmed pending the updated build's live test.

## First real playback verified, 2026-10-17

The live session exposed independent video/audio RTP source and sequence spaces, plus a genuine sequence gap. The adapter now assembles complete bounded DHAV frames per channel+SSRC, permits private payload-type changes, and resynchronizes after gaps. See the corrected native evidence in `analysis/native-http-credentials-and-rtp.md`.

The final black-preview cause was a display-rule conflict: the hardware callback cleared the video's inline display, revealing the stylesheet's `display:none`, and hid the canvas as well. Explicit `display:block` fixed the video surface. Muted autoplay is permitted, and hardware Live status now requires distinct browser-presented frames. Actual Garage footage with an advancing on-camera timestamp was observed in both the regular window and menu popover, with no iPad app process running. Main Gate also rendered an image, but changing frames were only independently verified for Garage. Long-duration uninterrupted playback remains unverified; changing preview surfaces during inspection restarted sessions, so that activity is not a continuous stability test.

The release app signature verifies, JavaScript syntax checks pass, and all 48 Swift tests pass. User-requested local test sign-in reads `.env` only with `--credentials-file`; Git ignores the user-managed file. No account tokens, camera keys or authenticated URLs are persisted. Detailed redacted evidence and IPA/REA results are in `analysis/relay-ats-follow-up.md`.

## Automatic session certificate exception, 2026-10-17

After confirming playback, the user requested automatic allowance until sign-out. This supersedes the earlier per-session confirmation workflow: successful sign-in now enables the existing exact-leaf exception, and sign-out or shutdown clears it. The review UI, stale-review state, and special expired-certificate error have been removed. Unexpected TLS failures still produce a redacted connection error. The certificate pin, TLS minimum, validation of unknown certificates, and account API trust policy are unchanged. No certificates are removed from the server or macOS trust store.

All 48 core Swift tests pass, including automatic session allowance, exact-pin matching, and revocation on sign-out/shutdown. The concurrent interface task's temporary screenshot test was excluded from execution. The release app was rebuilt and its signature verified, then relaunched using the user-requested local credentials file. It signed in and displayed Garage footage without a certificate prompt. Two native app captures showed the camera timestamp advance from 03:30:29 to 03:30:38 on 17 October 2026. Sign-out cleanup was tested at the model level; the live session was left signed in. This was a short playback check, not a long-duration stability test.

## Verification failure wording, 2026-10-17

The user supplied a screenshot of the verification page reporting `-50106` after a wrong-password attempt. Source inspection found the local page classified every `-501xx` error as an expired challenge, and the native subtitle suggested an incorrect password or unusual activity. Neither claim is established by the received CAPTCHA code. The subtitle now states that Imou requires a security check, and provider rejection displays `Verification could not load` with its sanitized code. Direct account/password rejection remains separate from PCS code 12114, which requests CAPTCHA. GeeTest's published error table does not define `-50106`; its exact service-side cause remains unverified. A Node VM check exercised provider rejection and network retry without fabricating success. No further wrong-password requests were sent to the real account, and no successful CAPTCHA completion is claimed.

## CAPTCHA loading and validation fixed, 2026-10-17

The focused REA follow-up resolved the loading cause: the official overseas V9.7+ client selects Geelab, but our page loaded legacy GeeTest. A real Imou-issued synthetic-account CAPTCHA ID reproduced legacy HTTP200/error -50106 (`not captcha`), while the corrected production page reached Verify in WebKit with the same ID. The page now uses Imou's official `gl4.js` and native display settings. This supersedes the preceding unknown/error-wording-only entry.

Completing the widget exposed a second error, CheckGeeTest4 code11010. Fresh Windows REA showed modern pre-login `postAuto` uses the default service identity and signed API version3.10.0, while our request used the account/password identity and version0. The corrected request retains native challenge metadata, the account GCM wrapper, and the five human-completed result fields. After the rebuilt app reopened, the user completed a fresh puzzle and confirmed cameras appeared; native inspection also reached Garage Live after reconnect. All50 Swift tests passed across49 core tests and the isolated host-access Keychain test. See `analysis/captcha-provider-fix.md` for evidence, runtime capture cleanup limitations, and `analysis/windows-captcha-loader-follow-up.md` for the complete static findings.

## Per-camera video quality, 2026-10-17

Added a quality menu to the single-camera preview and each grid tile. Options come from each camera's `mediaConfig.streamClarity`, retaining its name, stream channel, image size, and default. A bounded account metadata read confirmed Garage advertises 3MP/1080P/720P and Main Gate 2K/1080P/720P. Both advertise stream channel0 for all three qualities, with imageSize41/18/17, so the choice is keyed by both channel and image size. No account credentials, device identifiers, camera keys or media resources were printed during this read.

Changing quality requests a fresh `GetRealTransferStreamUrl` resource with the advertised streamId/imageSize pair. The single-camera preview reconnects, or only the affected grid tile reconnects. Choices are independent per camera and cleared on sign-out or quit. Removed options fall back to the camera's advertised default; cameras without an option list retain the previous default-request behavior and have no selectable quality menu.

The release build and signature verification pass. All53 core Swift tests pass, including four new tests covering multiple image sizes on the same stream, string-encoded metadata, malformed/duplicate options, independent camera choices, removed-option fallback, and sign-out cleanup. The unchanged Keychain test was excluded from this run. Runtime UI/playback switching is pending because macOS was locked during inspection; the user has been asked to unlock it.
