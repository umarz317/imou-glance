# CAPTCHA provider and validation fixes

Verified on 17 October 2026. Windows behavior below is static REA evidence;
the provider comparison and final sign-in were observed at runtime on macOS.

## Why the widget returned -50106

Windows' `LCGeeTestView::loadGeeTest` opens Imou's official page through CEF.
It passes the CAPTCHA ID, HTTPS, language, and width, with an optional Geelab
vendor setting. The current official overseas web client selects Geelab for
protocol V9.7.0 or newer. Our native client advertises V9.7.0 but its embedded
page always loaded the legacy GeeTest SDK. Both SDKs expose `initGeetest4`,
so testing only the global function's existence missed this mismatch.

An isolated synthetic account produced a genuine Imou verification request.
The same returned CAPTCHA ID was kept in memory and tested against both
providers. Legacy GeeTest returned HTTP 200, `status:error`, `code:-50106`,
and `msg:not captcha`. A two-webview harness then used the production HTML,
changing only the SDK URL for its legacy control. Its result was:

```text
CAPTCHA_ISSUED_TO_SYNTHETIC_ACCOUNT
CORRECTED_WIDGET_READY
LEGACY_WIDGET_ERROR -50106
PASS SAME_ID_LEGACY_50106_CORRECTED_READY_NO_CAPTCHA_SOLVED
```

The production page now loads Imou's public
`https://pc.imoulife.com/h5-pc-base-v6/static/gl4.js`, with native-matching
`language:en` and `nextWidth:340px`. There is no fallback to fabricated
verification, and the user completes the actual challenge.

Provider comparison REA evidence:
`ev_2029805ae7beee27aea7bb57d69422272c1cd50678dbd06cd2ca6e76bf3116cc`.
The full widget harness emitted PASS and exited zero, but REA's process
capture returned `cleanup_incomplete` because ownership of two WebKit helper
processes could not be verified. Its complete partial observation is saved in
ignored `pcs-captcha-runtime-follow-up.json`; it is not represented as a
successful complete REA capture. No unverified process was killed. The
repeatable harness source is `CaptchaProviderHarness.swift`.

## Why completing the puzzle then returned 11010

The user completed the corrected widget in Imou Peek and reached
`common.validcode.CheckGeeTest4`, which returned HTTP 200 / code 11010.
Fresh REA found another reconstruction error: modern Windows
`LCRequest::postAuto` chooses its default service identity before login and
signs with API version `3.10.0`. It supports default and signed-in UUID
identities, not the account/password identity our login CAPTCHA call used.
Its default service constants exactly match the existing
`VerificationProtocol.identity`. Legacy generated API version `152485` is
not the version used by this modern native UI request path.

`verifyCaptcha` now uses the default service identity and API version
`3.10.0` for both pre-login challenge purposes. The account/password identity
remains in memory for the actual sign-in retry. The encrypted account wrapper,
server-issued metadata/verification token, and five widget result fields are
preserved.

Decisive native REA evidence:

- postAuto: `ev_acc4a240d3ca30472387aa60b6fbba3e4f6824cfe0cfe0954034a2a4d1627974`
- supportPost: `ev_ebfeae77f6f420998426a492e95e8583e1f285971de93b6667b4d1528b83727d`
- setHeader: `ev_841e273ae7fe07062ed80d96a5545614f6c6fed9f0d1869baf58db779a1a7c70`

Full loader, provider selector, default-identity equality, and request-version
evidence is indexed in `windows-captcha-loader-follow-up.md`. Native REA
sessions opened for this work were closed.

## Validation

The release app rebuilt and its signature verified. Forty-nine core Swift
tests passed, including a new independent Python HMAC fixture for the modern
CAPTCHA service request; the separate existing Keychain test passed with host
access (50 tests total). The first sandboxed Keychain run failed due access,
so it was rerun in isolation rather than changing credential storage.

After relaunch, credentials were loaded from the user-authorized local file.
The user completed a fresh puzzle and confirmed that cameras appeared. Native
app inspection confirmed the Garage camera list and Live preview after a
reconnect. Full CAPTCHA completion/sign-in is therefore established, beyond
the earlier component-only widget checks. Long-duration playback is not part
of this check.

No passwords, account tokens, camera keys, authenticated URLs, or query values
were printed or stored. The provider comparison used a nonexistent synthetic
account; its CAPTCHA ID and generated challenge values stayed in memory.
