# Relay ATS follow-up — 17 October 2026

## Proven runtime blocker

The existing signed-in build was preserved for diagnosis. Its global approval byte was 1 after the user used Allow Until Sign Out. A bounded debugger retry hit the native server-trust delegate and `-[NSURLCredential initWithTrust:]`, then completed with URLSession -1200 and underlying TLS -9802. Thus the failure was not simply a missing approval or a skipped acceptance branch.

A further connection-scoped test of `SecTrustCopyExceptions` / `SecTrustSetExceptions` returned true but still failed. It did not change global/system trust. Redacted system-log processing for that process found six `ATS failed system trust` events, six trust-evaluation failures, and the matching -9802 marker. Only numeric diagnostics/counters were emitted; no log messages, authenticated addresses, request queries, passwords, tokens, keys or footage were saved. Debuggers were detached after each test.

Apple documents that manual URLSession trust handling cannot loosen requirements for an ATS-protected connection:
https://developer.apple.com/documentation/foundation/performing-manual-server-trust-authentication

This establishes the immediate reason the old optional exception was ineffective. It does not establish relay authorization, framing, decryption, or live video.

## Change

Strict/default requests still use URLSession and ATS. After explicit approval, native media uses Network.framework TLS with a TLS 1.2 minimum and HTTP/1.1. Its verify block checks the approval again and accepts the exact observed leaf SHA-256. Other leaves must pass SecTrust SSL chain, time and hostname validation. That fallback is system trust validation, not a claim of all URLSession ATS policy checks. Account requests and app-wide ATS settings remain unchanged.

The original signed request target and authentication headers are serialized in memory. No redirects are followed. A bounded incremental parser handles fixed, chunked, and close-delimited HTTP bodies before the existing private-media framer. Invalid/ambiguous framing and truncation fail explicitly. Cancellation tears down the socket, timeout, decoder queue and stream.

Independent review found that the old confirmation could restore approval after another preview signed out. Approval now requires a review ID from the current account generation. Reconnecting media does not invalidate that ID, but sign-out does. The user then found the native alert unclickable in the menu popover; the review was replaced with inline text and buttons.

Validation at this stage: 38 Swift tests passed, including signed-target preservation, default-off transport rejection, HTTP fragmentation/chunking/limits, stale approval rejection and reconnect survival. Release app built and verified its ad hoc signature. These tests are not live-camera evidence.

An attempted in-process transport-probe library was rejected by automatic approval review because injecting code into the signed-in process could access credentials and initiate network traffic. It was not loaded or executed. Normal app relaunch was used instead; the probe source/binary contains no user data and remains under ignored build/.

## Imou Life HD download and REA

Requested App Store ID: 1628746674. Downloaded using the existing ipatool App Store session to `analysis/Imou-Life-HD.ipa`; no purchase was needed.

- IPA size: 98,412,241 bytes.
- IPA SHA-256: `bd953b622ad367be8f5ded04dcf1cb84897344aa6057a4dfe69c0b10f46f7887`.
- Bundle: `com.imoulife.pad`, version 1.9.0, build 2026.0820.1917.
- IPA executable SHA-256: `6644d1b8605b7604daa44e144d60ad1f6833b13ef06c8792fb02f16684b70683`.
- Downloaded executable REA Mach-O evidence: `ev_27ee35e3efe6f63c5820ddd154771f5d700c354b4d1a47eb5946b2f8fb380177`.
- Its LC_ENCRYPTION_INFO_64 has cryptid 1, offset 16384, length 41353216. Shipped encrypted code cannot be treated as decompiled protocol evidence.

The same version is installed at `/Applications/Imoulife_iPad.app/Wrapper/Imoulife_iPad.app`. Its executable SHA-256 is `26ae3d6e060f319f90a7cfbb79088dc3c99c059460a1360e3c8363aea276eaae`; REA evidence `ev_5d7afe89b6c145e628435d260b1ee09b6017d897f62f45d35cbfc15bcfe49285`. It shares Mach-O UUID `3F0B061F-8170-3CB4-B785-F7920D1AFE8A`, with a different encrypted range (offset 225280, length 4096). The installed app declares NSAllowsArbitraryLoads. That does not prove which media transport it executes.

A focused REA string search for WSSE V2 / TLS setup in the installed executable timed out after 300 seconds; no decompilation conclusion is claimed. The session was closed. Existing Windows protocol findings remain static evidence; the subsequent HTTP 200 observation below establishes acceptance of the current reconstructed request for the tested camera/session only.

## Next runtime boundary

The user signed in and approved through the inline controls. The app then reported an unsupported media packet. Read-only runtime inspection established HTTP 200, Content-Type `video/e-rtpxav`, Private-Type `application/sdp`, Private-Length 583 and KeepLive-Time 30. There was no Content-Length or Transfer-Encoding. Body metadata showed an SDP prefix followed at offset 583 by `$` interleaved RTP, with DHAV at offset 599. No SDP values, media payloads, request secrets or authenticated URLs were emitted or saved. The debugger was detached.

The immediate rejection was caused by treating that SDP prefix as an RTP packet. The fix passes Private-Length through both transport paths, validates a decimal length bounded to 32 KiB, consumes exactly that many bytes across arbitrary reads, then starts ordinary media framing. It does not scan for `$` within SDP. Duplicate Private-Length fields are rejected by the HTTP parser. Windows corroboration is recorded in `analysis/native-sdp-framing.md`.

All 40 Swift tests pass, including synthetic end-to-end HTTP/SDP/media framing at every two-chunk split for RTP and XAV, plus invalid length and duplicate-header cases. The next real-camera test is decoding after this prefix fix. Live changing frames remain unconfirmed.

## First changing camera frames confirmed

The prefix fix reached valid DHAV headers, then exposed two separate issues. Runtime SDP metadata identifies video payload type 98 (H265/90000), audio 97 (MPEG4-GENERIC/16000), and application 100. Both audio and video carry DHAV; the first arriving audio packet could incorrectly lock the old adapter away from video. A redacted metadata trace confirmed audio/video have distinct SSRCs and independent sequence spaces. Another retry reached a genuine video sequence gap (19102 to 19239, unchanged SSRC), which the old adapter treated as fatal. Native evidence permits payload-type changes for private encodings and recovers after packet loss.

The adapter now keeps bounded channel+SSRC assembly states, emits complete declared-length DHAV frames, validates each header, suppresses duplicate/stale packets, and discards incomplete frames on gaps before resynchronizing. Eight sources and 5 MiB per frame bound retained assembly payload to 40 MiB. No extra trailer requirement was invented. All 48 Swift tests pass, including the new framing cases and local test credential reader.

The user explicitly requested `.env` sign-in to avoid repeated manual entry. The app reads it only with `--credentials-file`; the user manages that file, and the app does not persist credentials or session data. Git ignores `.env`/`.env.*`. Credentials were validated with presence-only output and used successfully for native sign-in. Certificate approval remains independent and clears on relaunch.

A black preview persisted despite decoder callbacks. WKWebView had required gestures for all media; it now permits the selected camera's muted video element to autoplay. More decisively, the hardware DecodeStart handler set `video.style.display = ''`, falling back to the stylesheet's `video { display:none }`, while also hiding the canvas. It now explicitly sets the video display to `block`. This final HTML-only fix was copied into the running app's public asset bundle and the app signature reverified, preserving the signed-in session. The user reported visible footage, and subsequent app screenshots showed actual Garage imagery with its on-camera timestamp advancing around 03:04 local on 17 October 2026. No iPad app process was running.

Hardware “Live” status now requires two distinct browser-presented video frames through requestVideoFrameCallback, rather than input-frame callbacks from the vendor decoder. JavaScript syntax checks pass. Actual changing Garage frames are proven; sustained playback and another camera are the next checks. Screenshots were inspected through the UI tool, not exported as footage files.

The menu popover subsequently displayed Garage imagery with on-camera timestamps 03:05:31 and 03:07:26. Main Gate also rendered a camera image around 03:06:44; a second Main Gate timestamp was not captured because the user switched cameras. Preview/window switching created new connections, so these observations do not prove an uninterrupted multi-minute session. The regular window and popover share a status model, and a hidden preview can currently overwrite the status of another visible preview (for example, Stopped while the other window retains imagery). Normal menu-only use and a single uninterrupted playback window are the next stability checks. No further app relaunch was performed after the final HTML fix; the signed-in session remained running.
