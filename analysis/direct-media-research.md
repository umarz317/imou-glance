# Direct consumer-camera playback investigation

Updated 2026-10-16. Read-only public-source research; no Imou login, personal token, camera request, or live playback performed. The Windows stream findings in [stream-findings.md](stream-findings.md) remain the consumer-protocol evidence. This investigation did not touch the shared REA native session.

## Result and implementation route

The public Imou web SDK contains an accessible **lower-level player accepting a negotiated media URL directly**. Its top-level `imouPlayer` obtains that URL using a developer `kitToken`, but its exposed `window.PlaySDKInterface` does not accept or require that token. This creates a concrete route for a standalone app: implement consumer PCS account login and stream negotiation in Swift, then feed the resulting authorized resource and device encryption information into the vendor's JavaScript/WASM decoder inside a menu-bar WKWebView.

This is a source-supported implementation strategy, **not yet a proven bridge between consumer PCS resources and the open-platform decoder**. The outstanding compatibility test is whether `things.media.GetRealTransferStreamUrl` produces a compatible relay URL, stream type and encryption parameters. Merely substituting a PCS account token for `kitToken` has no supporting evidence and should not be implemented.

## Public artifacts inspected

Official live SDK: <https://open.imoulife.com/imou-player/imou-player.js>. Its header identifies V1.5.0, built 2026-09-23. Downloaded bytes: 1,690,838; SHA-256 `d32f81e18b8d79d039f59fc091e7c53e96693dd615867932c17b41e79f15ecf4`.

Temporary local copy: `/tmp/imou-official-imou-player.js`. Offsets below are UTF-8 byte offsets in that exact copy, zero-based; they are source locations, not REA Evidence IDs.

| Source location | Observation |
| --- | --- |
| `1084500` vicinity, `wC()` | Browser/platform detection disables multithread mode unless `navigator.platform` starts with `Win`. Single-thread is the SDK's actual Mac path. |
| `1446891` | Public assignment exposes `window.PlaySDKInterface`. |
| `1458679`, wrapper `startPlay` | Constructs decoder, supplies DOM canvas/video, and calls `Init` then `StartPullStream`. URL, device key and optional playback-token fields are passed separately. |
| `1427207`, `StartPullStream` | Does transport setup directly; no `kitToken`, app ID or open-platform URL negotiation appears in this method. |
| `1432443`, `shouldAppendPasswordToPlayUrl` | Appends password-derived URL parameters for MIKEY, cloud AES, or a supplied device key. Keep complete resource query parameters. |
| `1432620`, `resolveStreamDecryptCredentials` | Chooses supplied device key, decoded playback credentials, or NVR credentials. |
| `1433125`, `setEncryptInternal` | Handles encryption modes 2, 3 and 5 through WASM/device-specific key derivation. Mode 1 needs audio/video key material. |
| `1304429` | Single-thread decoder creates `WasmLib/SingleThread/PlaySdkWorker.js`. |

The following official public files were successfully fetched into `/tmp` (same path flattened with `imou-official-` prefix):

| URL relative to `https://open.imoulife.com/imou-player/` | Bytes | SHA-256 |
| --- | ---: | --- |
| `WasmLib/SingleThread/liblcplay.js` | 79,090 | `23f4fa43adb98ad9ac7bf7fa897f6ea08a5491a7ebe2de1a285f3174e9c043c3` |
| `WasmLib/SingleThread/liblcplay.wasm` | 4,974,429 | `d1c127b86345a01991639de38438bf7b0b9d2357b7f9f1b7ad661dbd19f2320a` |
| `WasmLib/SingleThread/PlaySdkWorker.js` | 18,749 | `48918f1d17f82f92d4f7e0617904870770cea12d318733b562e2df0f815a2455` |

`PlaySdkWorker.js` requires an alphanumeric `v` query parameter and imports neighboring `liblcplay.js` with the same value. The current wrapper uses asset version `c4e6303`. Before loading decoder assets, call `PlaySDKInterface.setAssetVersion` and append that version to worker/WASM resources using `appendAssetQuery`. The wrapper initializes `window.LCPlayModule` through `window.LCPlaySDK_Module`; copy that startup sequence, then construct the decoder. The main bundle embeds its front-algorithm WASM.

## Direct decoder boundary

Reconstructed call shape from the wrapper, with all values supplied at runtime:

```javascript
const sdk = new window.PlaySDKInterface(false); // single-thread on Mac
sdk.setCallback('PlayStart', onStarted);
sdk.setCallback('Error', onPlaybackError);
sdk.setCallback('WebSocketCloseCallback', onDisconnected);
sdk.Init({
  canvasElem: canvas,
  videoElem: video,
  bPlayBack: 0,
  strDecodeFilePath: assetsBase + 'WasmLib/SingleThread',
  log_c: false,
  log_js: false,
  env: 2,
});
sdk.setVolume(0);
sdk.StartPullStream(
  { deviceId, channelId, code: deviceKey, playType: 'real', playSubtype: streamId },
  { playUrl: negotiatedResource, streamType, playToken, playTokenKey },
);
```

This shape excludes readiness, callback and teardown glue; it is an integration boundary, not a complete working player. Follow wrapper startup and call `StopPullStream()` and `stop()` when the popover closes or session ends. Disable vendor console/log caching in the embedded app: vendor source logs stream URLs and key derivation details when its logging paths are active.

The decoder reads `encrypt`, `tid` and `eventLiveID` from the resource URL. `playToken`/`playTokenKey`, when both present, are decrypted through `_PLAY_ParsePlayTokenExGcm` to obtain device login and media-encryption information. It can instead take a device key through `code`; that does not prove every consumer encryption mode works without a playback token.

For `streamType: rtsv`, it uses the relay authority from the negotiated URL, a WebSocket endpoint `/httpprivateoverwebsocket`, and a private live resource `/live/realmonitor.xav`. For `rtsp`, it uses RTSP-over-WebSocket. The wrapper's `wsPlay` handler obtains separate encryption keys for RTSP mode 1; the public API for this is `/openapi/getDeviceEncryptKey`, which itself requires `kitToken`. A consumer equivalent must come from the Windows PCS trace or a compatible RTSV branch. Do not silently leave mode 1 waiting for keys.

## Public API and FFmpeg limits

The [official SDK guide](https://open.imoulife.com/book/js/sdk.html) documents only `kitToken` at the public top-level API, plus H.264/H.265 playback and a device decryption key. It lists Chrome/Firefox/Edge; it does not promise WKWebView/Safari support. Source has Safari detection and a software/canvas single-thread decoder. Validate WASM initialization, worker loading, WebGL and a changing camera frame in WKWebView before claiming macOS runtime support.

Imou's [official open-source device client](https://github.com/Imou-OpenPlatform/Py-Imou-Open-Api/blob/main/pyimouapi/device.py), `async_get_rtsp_stream_url`, obtains a short-lived cloud URL via `getStreamUrl`, passing device ID, channel, stream ID and optional product ID. Its [HA device wrapper](https://github.com/Imou-OpenPlatform/Py-Imou-Open-Api/blob/main/pyimouapi/ha_device.py) passes that URL to Home Assistant. The client authenticates with **developer app ID/secret**; this does not establish consumer PCS-token compatibility. It is evidence that some authorized cloud routes are standard RTSP, not a completed solution to normal account sign-in.

[FFmpeg's primary documentation](https://ffmpeg.org/ffmpeg-protocols.html#rtsp) supports standard RTSP/RTP over TCP and RTSP over HTTP(S); it does not establish support for Imou's encrypted DAV/RTSV private frames. A standard decrypted RTSP resource could use FFmpeg directly. A resource containing `proto=Private3`, media encryption or private framing must be proven compatible or handled through the vendor decoder. No official public Imou source found in this bounded research establishes a universal consumer-cloud FFmpeg URL.

## Next decisive checks

1. Finish consumer PCS sign-in and preserve the device/channel media configuration already identified in Windows, including encryption type and authorized device credentials.
2. Recover exact `GetRealTransferStreamUrl` request/response and the selected RTSV/RTSP branch. Do not guess the returned resource scheme or replace ports.
3. Initialize the bundled single-thread decoder in an isolated WKWebView using public assets only; this can be tested before user sign-in.
4. With the user's own successful app sign-in, request one camera resource on demand and pass it through the lower-level boundary. Keep URL, credentials and tokens out of logs and persistence.
5. If encryption mode 1 appears, recover its consumer audio/video key endpoint. If RTSV is compatible, prefer it for the first direct preview because its wrapper avoids the separate developer key request.

## Implemented bridge and runtime validation

The subsequent implementation in `Sources/ImouMac/DirectPlayerView.swift` and `PlayerAssets/player.html` bundles the pinned public SDK files above. `PROVENANCE.txt` records their unchanged hashes. The Swift view uses a nonpersistent WKWebView and a loopback HTTP listener bound to `127.0.0.1` on an ephemeral port. That listener serves five fixed public routes only; stream configuration is injected through `callAsyncJavaScript` arguments, never HTTP, source interpolation or persistence. User media capture permissions are denied. Hidden/dismantled views stop playback and clear the canvas.

The vendor's transport chooses cleartext `ws` on an HTTP page unless the resource contains `8556`, so merely supplying `tls_resource` was insufficient. The local bridge enforces `wss` using an early WebSocket constructor wrapper while preserving the vendor-provided authority, explicit port, path and query. CSP also denies cleartext WebSocket connections. The account client must supply `tls_resource` exclusively; this does not transform a non-TLS relay into a TLS server.

On 2026-10-16 an isolated compiled macOS harness passed:

1. Loopback listener startup and fixed-route serving.
2. Unknown route and POST rejection with HTTP 404.
3. Complete 4,974,429-byte WASM response with `application/wasm` MIME type.
4. Actual WKWebView main decoder WASM initialization.
5. Actual `PlaySDKInterface.Init` single-thread worker initialization (`initCompleted == true`), then decoder stop, without calling `StartPullStream`.
6. A local Node mock verified the WebSocket wrapper forces TLS while preserving explicit ports 80, 443 and 8556, preserves existing secure URLs, and rejects non-WebSocket schemes.
7. A local mocked-decoder check verified that the bridge reports playback only after decoded-frame metadata, stops the decoder, waits for worker readiness, releases the vendor's unencrypted (`encrypt=0`) packet gate, and rejects unsupported/MIKEY encryption and invalid resource schemes. These assertions do not substitute for media playback.

The exact harness output was `LOOPBACK_READY`, `FIXED_ROUTES_OK`, `MAIN_WASM_READY`, `PASS WORKER_INITIALIZED`. It was rerun successfully after TLS enforcement. No account, camera URL or media request was used. This proves the pinned decoder initializes in macOS WKWebView; consumer account authentication, relay authorization, decryption and changing live frames remain unvalidated. The bridge rejects MIKEY (`encrypt=1`) explicitly until its consumer key endpoint is recovered, and reports playback only after decoded-frame callbacks.

## Automatic device credentials

`DirectStream` now accepts optional `deviceLoginName` and `deviceLoginPassword` fields, both defaulting to nil. The bridge assigns the provided values to the decoder's `devLoginName` and `devLoginPassword` after worker initialization and before `StartPullStream`. A valid `playToken` pair can still override these fields inside the vendor method. The normal automatic flow passes `code: ""`; this preserves the vendor's automatic credential path and avoids adding the manual-code `key`/`keys` query parameter to the authorized relay resource. Explicit code overrides remain supported by the bridge but are not required for automatically resolved credentials.

The unchanged pinned bundle's relevant raw UTF-8 byte sites are: `StartPullStream` at 1427205; playback-token credential assignment at 1428613; `userInputCode` assignment at 1429120; RTSV transport `setUserInfo` at 1431074; `shouldAppendPasswordToPlayUrl` at 1432443; `resolveStreamDecryptCredentials` at 1432620; and `setEncryptInternal` at 1433125. With empty code, the resolver uses `devLoginPassword` both as decryption input and as transport login password. For mode 5, it supplies that string and device ID to `getDecryptKey`, which calls `_PLAY_ParseDecryptKey` (1312819) and returns a 49-byte array. No `wssekey` or `deviceAccount` input/setter exists in this bundle; do not treat an already-derived media key as a plain device password without native evidence establishing the representation. The RTSV constructor defaults the login name to empty; this source supplies no evidence that a missing consumer username should become `admin`.

An isolated macOS WKWebView harness exercised the actual local bridge with synthetic credentials, real vendor decoder initialization and real mode-5 derivation. It intercepted `StartPullStream` before transport setup, verified the injected fields and resolver output, verified empty-code operation does not request a manual password URL parameter, and observed a 49-byte derivation result. Output: `PASS AUTOMATIC_CREDENTIALS_AND_MODE5_DERIVATION_NO_NETWORK`. No key bytes or credentials were printed. This verifies argument plumbing and the derivation call shape, not authorization or successful decryption of an actual camera stream.

## TLS resource scheme adapter

The native-parser investigation established support for both `rtsp://` and `rtsps://` resources. The pinned [official JavaScript source](https://open.imoulife.com/imou-player/imou-player.js), `StartPullStream` at UTF-8 byte 1427205, removes only the literal `rtsp://` prefix before extracting the relay authority and opaque source segment. Its top-level `getPlayUrl` copies the returned `url` without a scheme adapter. Therefore a native `rtsps://` resource needs a prefix-only `rtsps://` → `rtsp://` conversion for this JavaScript parser. This is an internal parser carrier; the bridge still forces the resulting transport to `wss://` and preserves the exact server authority and explicit port. The original opaque path/query must remain unchanged; no HTTP, schemeless or guessed-port conversion is supported by this evidence.

The vendor selects the first segment following the authority as an opaque `sourceId`, then sends it to its separate `/live/realmonitor.xav` endpoint over `/httpprivateoverwebsocket`. Reconstructing a conventional nested live URL would change this behavior. The prefix adapter fixes a proven compatibility gap; no actual user resource scheme or successful live connection was observed during this bounded investigation.

## Consumer HTTP resource and native transport boundary

Subsequent redacted inspection by the parent established that the account's actual TLS resource is a bare `host:port/live/realmonitor.rtpxav?<opaque query>`, rather than an RTSP scheme carrier. The Windows factory preserves the complete resource after the first slash and supplies TLS independently. Consequently the prefix adapter above alone cannot adapt this consumer resource to the browser SDK's different source-ID request shape.

An isolated macOS harness executed the actual SDK with a synthetic nested `.rtpxav` resource and a fake WebSocket. It observed the SDK open `/httpprivateoverwebsocket` and send `/live/realmonitor.xav?...?sourceId=live`, losing the remaining path and authorization query. Injecting a synthetic HTTP 401 caused another HTTP request without an Authorization header. Static source agrees: the private HTTP constructor does not append the digest header it computes for its RTSP branch. Output: `PASS VENDOR_TARGET_TRUNCATION_AND_MISSING_HTTP_DIGEST_NO_NETWORK`. This used no account or camera and made no media connection.

The local `player.html` now supports a separate native HTTPS transport while retaining the real SDK's normal `StartPullStream` encryption setup. A nonempty `config.nativeSessionId` for RTSV supplies an object in `player.webSocket` before that call. It captures the SDK's packet and open callbacks; `connect` posts only `{action:'start', sessionId}` to the native `nativeTransport` message handler. `disconnect` posts `{action:'stop', sessionId}`. Swift retains the authorized request; URLs, login credentials and WSSE headers are not copied into these messages.

The native-facing JavaScript API is:

- `nativeTransportOpened(sessionId)`: call after successful native HTTP response, before packets. Invokes the real SDK video-open callback and releases its unencrypted-packet gate when needed. It does not report Live.
- `receiveNativePacket(base64, sessionId) -> Bool`: passes one already separated **vendor-compatible payload** unchanged to the captured `rtpDataCallback(bytes, 'video')`. It rejects stale sessions, packets before open, stopped sessions, invalid Base64 and payloads above the worker's fixed 5 MiB input-array capacity.
- `nativeTransportFailed(sessionId, status)`: stops the matching current stream and reports one bounded error status. Stale IDs cannot stop a newer stream.

An actual WKWebView harness initialized the real decoder/worker, executed the real mode-5 key setup, captured the packet callback before decoding, and verified exact synthetic bytes `[0,1,2,255]`, zero WebSocket construction, start/stop messages, stale/pre-open/stopped rejection, mode-0 packet-gate release and current-session timeout cleanup. Output: `PASS NATIVE_TRANSPORT_BRIDGE_KEYS_BYTES_LIFECYCLE_NO_NETWORK`. These are transport-plumbing and key-setup checks; the synthetic bytes were deliberately intercepted before media decoding.

## RTP framing and decoder compatibility limit

Windows native analysis distinguishes `.rtpxav`'s four-byte `$`, channel, BE16-length framing from the browser SDK's six-byte `$`, channel, BE32-length framing. The browser SDK's `dA` private receiver strips its six-byte header and forwards the payload unchanged. The worker then calls `_PLAY_ParseStream(ptr,len)`, whose transcode callback supplies frames to `_PLAY_InputData`. Neither browser transport branch performs standard RTP depacketization in JavaScript. Its `setStreamType` only records a diagnostic stream-type value.

The bundled WASM contains a real `Basic::StreamParser::CRTPStream` implementation: disassembly at `0x231cc9` checks a minimum 12-byte RTP header, version bits and configured payload types. Its existence does not establish automatic selection/configuration through the exported parser. To test that boundary, an isolated harness generated twelve H.264 I-frames locally using FFmpeg (37 NAL units, 30,289 bytes), wrapped them as standard RTP payload type 96, and exercised the actual initialized WASM parser. Raw RTP, four-byte-interleaved RTP and six-byte-framed RTP each produced **zero** transcode callbacks. The positive control, the same NAL units with Annex B start codes, produced **eleven** transcode callbacks containing 27,982 bytes. No parser traps occurred. Output: `PASS SYNTHETIC_RTP_PARSER_PROBE_NO_NETWORK`.

Therefore stripping four bytes from an arbitrary `.rtpxav` packet and feeding its RTP body into this bridge is not established as compatible. Standard RTP needs codec-aware depacketization and any Imou encryption/metadata handling proven by the native pipeline. A native HTTPS response using the SDK's `/live/realmonitor.xav` six-byte private packaging would match the demonstrated vendor payload boundary, but changing a consumer relay's path while retaining its query remains an authorized runtime compatibility probe, not a source-proven server capability. No live frame or successful camera decryption was claimed by these tests.
