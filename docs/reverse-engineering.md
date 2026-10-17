# How Imou Glance was reverse engineered

This guide explains how Imou Glance (formerly Imou Peek) became a standalone camera viewer. Follow
the numbered steps for the overview; the linked reports contain function
addresses, REA evidence IDs, protocol details, and test results.

**Last verified: 17 October 2026.** Windows binaries were inspected statically
with REA. The rebuilt macOS app was tested against real cameras. Static code
findings and synthetic tests were treated as clues until runtime checks
confirmed the relevant behavior.

## The playback path

```text
Imou sign-in
  → security puzzle / Mac authorization, if requested
  → camera list and camera credentials
  → encrypted stream resource from Imou
  → native HTTPS connection
  → remove transport headers
  → vendor WebAssembly decoder
  → visible camera frames
```

The app uses Imou's cloud relay. "Direct" means it makes its own account and
media connections; it does not mean every connection is local or peer-to-peer.
It does not capture the iPad app's screen.

## 1. Identify the shipped components

The supplied Windows installer was extracted. REA was used to follow specific
functions, rather than guess behavior from strings alone.

| Component | What it established |
| --- | --- |
| `LCBaseLogic.dll` and `RestApimd.dll` | Sign-in, request signing, device discovery, and media requests. |
| `LCCommon.dll` and `LCBaseCommon.dll` | CAPTCHA loading, account encryption, and modern validation requests. |
| `StreamPCSDKmd.dll` | Media authentication, TLS setup, and private media framing. |
| Official Imou web assets | CAPTCHA provider selection and the browser decoder. |

The requested Imou Life HD IPA was also inspected. Its main executable was
encrypted, so it did not establish how the iPad app validates relay
certificates. That behavior was not verified at runtime.

Evidence: [account protocol](../analysis/pcs-config.md),
[Windows CAPTCHA loader](../analysis/windows-captcha-loader-follow-up.md),
and [IPA findings](../analysis/relay-ats-follow-up.md#imou-life-hd-download-and-rea).

## 2. Reconstruct account sign-in

1. `user.account.GetToken` checks the account and returns session information.
2. `user.account.Login` uses the returned identity to finish signing in.

Native code established the exact body hashes, HMAC signatures, line endings,
timestamps, nonces, and session headers. Swift's CryptoKit implements them;
independent fixtures check the results. The password-derived identity and the
later session identity are kept separate.

HTTP success alone is not enough. The app also checks Imou's result code and
any reported credential failure. It accepts only supported HTTPS account
servers and refuses redirects.

Code: [ImouClient.swift](../Sources/ImouMac/ImouClient.swift) and
[PCSSigner.swift](../Sources/ImouMac/PCSSigner.swift).

## 3. Handle human verification

Imou can request either of these before sign-in finishes:

- **Code 12112:** authorize this Mac using a code sent to the registered account.
- **Code 12114:** complete a security puzzle.

These are separate branches. A puzzle request does not by itself prove that
the password was wrong.

Two mistakes caused the CAPTCHA failures:

1. **`-50106`: wrong provider.** The official overseas client selects Geelab
   for protocol V9.7.0 and newer. Our page loaded legacy GeeTest. With the same
   Imou-issued CAPTCHA ID, legacy GeeTest returned `not captcha`, while Geelab
   reached **Verify**. The page now loads Imou's official `gl4.js`.
2. **`11010`: wrong validation signing.** Modern Windows uses the default
   service identity and API version `3.10.0` before login. Our request used the
   account/password identity and version `0`. The corrected request preserves
   Imou's original metadata and the user's completed puzzle result.

The user then completed a fresh puzzle in Imou Glance. Imou accepted the result
and returned the camera list. No CAPTCHA solver or fabricated success was used.

Evidence: [CAPTCHA fixes](../analysis/captcha-provider-fix.md) and
[Mac authorization](../analysis/terminal-verification-findings.md).

## 4. List cameras and retrieve their passwords

The app reads the account's devices, then requests channel and media details.
A camera can have its own encrypted credentials, separate from the account
password.

When necessary, `iot.control.DevicePasswordGet` retrieves those credentials
using the signed-in account and a fresh random salt. The response's encryption
type determines how it is decoded. The normal interface does not ask for a
manually entered camera safety code.

Camera credentials remain in memory. The optional login Keychain entry stores
account sign-in details, not camera keys or stream tokens.

Code: [CameraSession.swift](../Sources/ImouMac/CameraSession.swift) and
[DeviceSecret.swift](../Sources/ImouMac/DeviceSecret.swift).
Evidence: [automatic credentials](../analysis/automatic-device-credentials.md).

## 5. Request and authenticate the stream

`things.media.GetRealTransferStreamUrl` returns the stream resource. In the
tested account, `tls_resource` was an address and port followed by a path and
an opaque query, rather than a complete URL with a scheme.

The app preserves that resource and connects over HTTPS. Windows evidence
established the WSSE UsernameTokenV2 headers and the ordinary `method=0`
control parameter. The exact request target is signed.

The vendor browser transport changed the path, dropped query information, and
omitted required HTTP authentication for this consumer resource. Swift
therefore owns the connection and passes media bytes to the decoder.

Code: [NativeStreamAuthentication.swift](../Sources/ImouMac/NativeStreamAuthentication.swift).
Evidence: [native HTTP media protocol](../analysis/native-http-media-protocol.md).

## 6. Connect to the relay

The tested relay's certificate was expired and did not match its address.
macOS rejected it with URLSession `-1200` and TLS `-9802`. The leaf certificate
expired on 20 March 2020; the intermediate expired in 2024.

Static Windows analysis found that its default media connection disables
certificate verification. Imou Glance's first URLSession trust exception still
failed because App Transport Security continued rejecting the connection.

The working path uses Network.framework, TLS 1.2 or newer, and the one exact
observed leaf certificate. At the user's request, that exception becomes
active after sign-in and clears on sign-out or quit. Unknown certificates
must pass system chain, time, and hostname validation. Account API validation
and the macOS trust store are not changed.

This does not repair Imou's certificate. Someone holding its private key could
impersonate the relay.

Code: [LegacyRelayCertificate.swift](../Sources/ImouMac/LegacyRelayCertificate.swift) and
[LegacyRelayConnection.swift](../Sources/ImouMac/LegacyRelayConnection.swift).
Evidence: [TLS findings](../analysis/native-media-tls.md) and
[ATS runtime findings](../analysis/relay-ats-follow-up.md).

## 7. Separate media from transport headers

An accepted connection initially failed with **unsupported media packet**.
Its body started with SDP, a text description of the stream. The parser had
incorrectly assumed the first byte would already be media framing.

The corrected parser:

1. Reads the HTTP response and its declared `Private-Length`.
2. Consumes exactly that many SDP bytes, even across split network reads.
3. Selects private XAV or private RTP framing from the response type.
4. For RTP, removes packet headers and assembles complete DHAV frames.
5. Tracks independent channel/source sequence spaces and recovers after gaps.

XAV and RTP use different packet-length formats. Bounds checks prevent
unbounded buffering and the joining of unrelated partial frames.

Code: [NativeHTTPResponseParser.swift](../Sources/ImouMac/NativeHTTPResponseParser.swift) and
[NativeMediaFramer.swift](../Sources/ImouMac/NativeMediaFramer.swift).
Evidence: [SDP framing](../analysis/native-sdp-framing.md) and
[RTP recovery](../analysis/native-http-credentials-and-rtp.md).

## 8. Decode and display actual frames

The app bundles Imou's JavaScript/WebAssembly decoder in an ephemeral
WKWebView. A loopback server serves fixed public decoder assets. Native media
authentication headers stay outside the decoder configuration.

The final black-preview bug was a CSS conflict. The hardware video callback
cleared an inline display value, exposing a stylesheet rule that hid the
video. The canvas was hidden too. Explicit `display:block` made the decoded
footage visible.

Hardware **Live** status now requires distinct browser-presented frames,
rather than compressed-frame callbacks alone. Garage footage with an advancing
camera timestamp was observed with the iPad app closed. Main Gate also
rendered footage, with a smaller verification scope.

Code: [DirectPlayerView.swift](../Sources/ImouMac/DirectPlayerView.swift) and
[player.html](../Sources/ImouMac/PlayerAssets/player.html).
[Decoder provenance](../Sources/ImouMac/PlayerAssets/PROVENANCE.txt) records
vendor versions and checksums.

## Repeat the process safely

1. Reproduce one failure and note its stage and numeric error.
2. Find the matching native function or official web component with REA.
3. Record the artifact hash, function address, evidence ID, and uncertainty.
4. Change only the behavior supported by that evidence.
5. Run a focused fixture or component check, then the relevant Swift tests.
6. Build with `bash scripts/build-app.sh` and test the real app.
7. Confirm the actual outcome: accepted sign-in, camera discovery, or changing
   frames. A test pass, HTTP 200, or decoder callback alone is not enough.

Keep passwords, account tokens, camera keys, authenticated URLs, and query
values out of logs and reports. Reuse an active session when practical. Leave
puzzles and account codes to the user, and close analysis sessions afterward.

The last recorded validation passed 50 Swift tests. This documentation update
did not repeat runtime tests. Long-duration playback and every camera model
remain unverified. The [implementation history](implementation.md) preserves
earlier stages; read later follow-ups before treating an old limitation as current.
