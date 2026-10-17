# Direct consumer-account media path

Static Windows analysis, with an implementation lead supplied by the official browser SDK research in `analysis/direct-media-research.md`. No account session, live stream, or camera-password decryption has been executed by this worker.

## Conclusion

The Windows app deliberately supports both `RTSV1` and `RTSP` cloud relay negotiation. The official browser player researched separately accepts these transport URLs directly, making its packaged WebAssembly media layer a stronger standalone macOS implementation option than attempting to port the Windows streaming DLL or assuming AVPlayer can handle encrypted Imou streams. The account and media endpoint work remains separate from the browser player's transport/decode implementation.

Keep the media configuration and returned URL intact. An encryption mode is a protocol setting, not permission to remove encryption or disable authentication. The initial implementation should use the device's reported mode and the shipped protocol translation below.

## Shipped binary identity and address mapping

`analysis/installer/bin/StreamPCSDKmd.dll` SHA-256 `abaa4cb9b280ac042e32f65ab93d591e73ca25b8ab668f6b0bc5b39a069daa9a`.

Image base `0x180000000`. For this build, `.text` VA = raw file offset + `0x180000c00`; `.rdata` VA = raw file offset + `0x180001a00`. All instruction addresses below are VA, not raw offsets. Raw strings and hashes from the earlier report remain valid.

## Exact negotiation behavior recovered from instructions

Main function: VA `0x1800c23f0`–`0x1800c45c3`, inferred name `LCSDK_RestManager::getRealTransferStreamUrl` corroborated by its source log strings.

Evidence: `analysis/stream-getreal-annotated.asm` (complete disassembly for the PE unwind function range), with raw form in `analysis/stream-getreal.asm`. `objdump` displayed nearest exported symbol names that are **not** reliable function names; use addresses and the log strings.

- `0x1800c4005`: loads `/pcs/v1/things.media.GetRealTransferStreamUrl`.
- `0x1800c3fce`–`0x1800c3fea`: assigns the request parameter object to the root object's `data` key.
- `0x1800c3b30`–`0x1800c3bf8`: `data.type` is the string `RTSV1` if the protocol argument equals `1`, otherwise the string `RTSP`.
- `0x1800c25a5`–`0x1800c2638`: request `encrypt` string translation:
  - native encryption mode `1` + protocol `1` → string `"2"`;
  - native encryption mode `1` + another protocol → string `"1"`;
  - native modes `0`, `3`, `5` → same decimal string;
  - other native modes log `getRealTransferStreamUrl failed[encrypt=...]` and continue with the initially empty string. Do not copy this weak error handling; unsupported modes should produce a clear compatibility error.
- `0x1800c3a50`–`0x1800c3b1d`: assigns `productId`, `deviceId`, `channelId`, `streamId`, and translated `encrypt` using the same string assignment routine.
- `0x1800c3c70`: `windowNum` is assigned using a temporary formatted string, not the integer assignment routine.
- `0x1800c3c9f`–`0x1800c3d4e`: `design` string is `second` if a design argument is nonzero, otherwise `first`.
- `0x1800c3d61`–`0x1800c3da9`: `assistStream` is assigned the string `true`.
- `0x1800c3dbc`–`0x1800c3e10`: `skipAuth` is present only if its caller flag is true. Preserve normal account authentication; this does not establish authorization to enable it in our implementation.
- `0x1800c3e23`–`0x1800c3e94`: `imageSize`, `audioType`, and `videoLimit` use integer assignment; `timeLimit` uses a distinct boolean assignment with value false. `videoLimit` is integer zero.
- `0x1800c3ea6`–`0x1800c3fab`: optional bind arguments add `bindDid`, `bindCid`, `bindPid`, and nested `targetDevice` with keys `chn`, `pid`, `sn`.
- `0x1800c4091`: passes serialized JSON and route to REST adapter at `0x1800bebb0`.
- `0x1800c42cb`–`0x1800c43b7`: response selection is `response.data.tls_resource` if the caller TLS flag is true, otherwise `response.data.resource`; selected value is converted to string and copied to the output URL.

Complete REA/Ghidra decompile is now saved as `analysis/stream-getreal-pseudocode.json`, with readable `analysis/stream-getreal-pseudocode.c`. Evidence ID: `ev_8b94fc1e7f8299e35f5b32ce7d20e4264a0acf4340e9563a430a3ef3734cf6e8`. Provider Ghidra 12.1.4, operation `procedure_pseudo_code`, procedure `0x1800c23f0`, profile digest `2f8e96b5753c9076371d59a3c3682f610a66fa4834dc6dc5f556e707a6b8c2cf`. Default auto-analysis completed. Pseudocode is a reconstruction, not original source.

Recovered function parameter mapping (count includes `this` as parameter 1):

| Parameter | Meaning supported by assignments |
|---|---|
| 1 | REST manager `this` |
| 2 | device ID string |
| 3, 4 | Pointers to local 32-bit output/metric slots, **not credentials**; written by REST adapter at `0x1800beb6b`–`0x1800beb8b` |
| 5 | channel ID string |
| 6 | stream ID string |
| 7 | Native encryption mode integer |
| 8 | Protocol integer (`1` → RTSV1, other → RTSP) |
| 9 | Design selector (`0` → first, other → second) |
| 10 | Window count, formatted as decimal string |
| 11 | Optional skip-auth caller flag; leave false for normal authenticated use |
| 12 | TLS-resource selection flag |
| 13 | Optional explicit server descriptor; null selects main configured PCS client; reset to null after failed MQTT branch |
| 14 | Output URL string |
| 15 | Product ID string |
| 16 | Audio type integer |
| 17 | Image-size integer |
| 18 | Output source/method indicator; MQTT success sets it to 2 |
| 19 | Optional MQTT request context/identifier; empty → skip MQTT and use REST |
| 20 | Bind product ID string |
| 21 | Bind device ID string; empty → omit bind/target fields |
| 22 | Target channel integer |

Exact REST payload reconstruction, with symbolic values rather than guessed device defaults:

```javascript
{
  data: {
    productId: productIdString,
    deviceId: deviceIdString,
    channelId: channelIdString,
    streamId: streamIdString,
    encrypt: translatedEncryptionString,
    type: protocol === 1 ? "RTSV1" : "RTSP",
    windowNum: String(windowCount),
    design: designSelector === 0 ? "first" : "second",
    assistStream: "true",
    imageSize: imageSizeInteger,
    audioType: audioTypeInteger,
    timeLimit: false,
    videoLimit: 0
  }
}
```

Optional bind fields and `skipAuth` are described above. IDs, `encrypt`, `windowNum`, `assistStream`, and `design` are strings even where numeric/boolean values might seem more natural. JSON primitive types were corroborated with value setters: `0x18047cea0` writes JSON type 1 (signed integer), and `0x18047d060` writes type 5 (boolean).

The single direct native callsite is VA `0x1800d4a02`; it supplies encryption/protocol from its object offsets `+0xb0` and `+0xb4`. The high-level field names at these offsets still require caller/class reconstruction.

### Optional MQTT branch

When parameter 19 is nonempty, the method first attempts `iot.control.SetIotService` (product ID nonempty) or `iot.control.SetService` (empty product ID), service `96500`. Root request uses `api` and `params`, whose parameters include `inputData`, product/device IDs, integer channel ID and optional target-device fields. `inputData` maps `96504` to translated encryption string, `96509` to stream ID, `96511` to RTSV1/RTSP, `96513` to window-count string, `96502` to audio-type string, and `96505` to image-size string. Its success URL comes from `params.data.outputData["96523"]` for TLS or `["96521"]` otherwise. A nonempty success URL sets output source indicator to 2. If MQTT does not succeed, the method ordinarily falls back to REST; recognized codes `13208` (`0x3398`, logged unlimit stream) and `13002` (`0x32ca`, offline) return directly. This optional branch is not required to construct the independent REST negotiation request.

## Stream-server login behavior

Function VA `0x1800bf320`–`0x1800bf723`, log name `LCSDK_RestAdapter::loginRemoteServersDetails`.

Evidence: `analysis/stream-loginserver-annotated.asm`.

- Creates a separate host/IP-specific `hsview` client from the server parameter.
- `0x1800bf3cf`–`0x1800bf415`: takes two strings from REST adapter object offsets `+8` and `+0x28` and passes them to function `0x1800bd9f0` with a final zero argument. The existing initialization strings call these `m_authUserName` and `m_authPassWordMd5`, but the exact header/auth scheme inside the called routine is still unverified in this worker.
- `0x1800bf432`–`0x1800bf448`: exact route `/pcs/v1/things.media.LoginStream`, exact body `{"data":{}}`.
- `0x1800bf523`: request via internal client routine at `0x1800923b0`.
- `0x1800bf5e8`–`0x1800bf5f7`: success checks request return zero and HTTP status 200. This caller does **not** parse a JSON playback token from the response.
- Frees response buffers and destroys the temporary client.

### Account auth source and REST-adapter dispatch

The native-UI worker recovered LCBaseLogic `SetPostClientInfo` (actual VA `0x180242f30`), saved `analysis/installer/pcs-clientinfo.c` and complete evidence `analysis/pcs-clientinfo-evidence.json`, Evidence `ev_0c481ab7a8ff5225897191f9f1c9b41638d0600919f9f0a3773b45c652f93cf0`. It passes the `uuid\` account principal and UserInfo token to `LCSDK_Api::initRestApi`. These are the auth inputs behind the adapter's historically named `m_authUserName`/`m_authPassWordMd5` strings; the token must not be blindly MD5-hashed.

Disassembly corroboration:

- Auth helper `LCSDK_SetRestClientAuthEx` VA `0x1800bd9f0`–`0x1800bddf0`, evidence `analysis/stream-clientauth-annotated.asm`.
- Prefix helper VA `0x1800bde00` compares username's first eight bytes to `account\` (raw string offset `0x870508`). Only `account\` principals perform credential hashing. For `uuid\` principals, mode 0 passes the credential/token unchanged to underlying auth setter VA `0x180090470`.
- `LoginStream` passes mode 0; with the consumer UUID principal this means a token credential, not the consumer account password and not MD5(token).
- REST adapter VA `0x1800be830`–`0x1800bebb0`, evidence `analysis/stream-restadapter-annotated.asm`: when the explicit-server descriptor is null, `0x1800beb12` calls the main configured `hsview` client at `this[0]` through wrapper `0x1800921d0`. A nonnull descriptor takes an alternate URL/client helper `0x1800bf7a0`.
- Therefore consumer `GetRealTransferStreamUrl` can use the main authenticated PCS client. No additional credentials occur in the method's JSON or parameters 3/4. Exact HTTP challenge/header serialization remains the root worker's RestApimd investigation.

### Defaults and caller-derived options

`analysis/stream-urlcaller-pre.asm` preserves the beginning of sole direct caller VA `0x1800d3010`–`0x1800d5810`; actual call is at `0x1800d4a02`.

- At `0x1800d3065`–`0x1800d30a6`, `audioType = (protocol != 0 && design != 0) ? 1 : 0`. Thus `design:"first"` gives `audioType:0`; `design:"second"` plus protocol RTSV1 gives `audioType:1`.
- Parameter-object constructor writes window count `-1` at `0x1800b573d` and image size `-1` at `0x1800b5770`.
- `playRTStream` propagation overwrites these with caller arguments at `0x1800ee777` and `0x1800ee79b`. Preserve the camera's media configuration where available; a missing-image-size fallback of `-1` matches parameter-object initialization, whereas zero is not established.
- An explicit window count of 1 for this app's single camera view is a reasonable product choice, not an observed Windows UI default.

## Media player integration handoff

The official player worker reports this lower interface (see its separate report for upstream URL, bundle digest, source evidence, and limitations):

```javascript
const sdk = window.PlaySDKInterface(false);
sdk.StartPullStream(
  {
    code: deviceKey,
    deviceId,
    channelId,
    playType: 'real',
    playSubtype: streamId
  },
  {
    streamType: 'rtsv', // or 'rtsp', matching the negotiated mode
    playUrl: returnedResource
  }
);
```

`playToken` and `playTokenKey` are optional fields; when available together the player can decode richer auth data. They are **not** established as outputs of the Windows `GetRealTransferStreamUrl` function by the current evidence. `code` is the authorized device password/key; do not substitute the consumer account password.

The player can parse encryption and tracking query fields from the URL. Preserve server-supplied query fields. Avoid logging URL secrets or device keys; send them to the renderer only for the active authorized camera.

## Useful follow-up functions

If exact native media auth remains necessary:

| Function | VA |
|---|---|
| GetRealTransferStreamUrl | `0x1800c23f0` |
| REST adapter request | `0x1800bebb0` |
| LoginStream caller | `0x1800bf320` |
| Client auth setter called by LoginStream | `0x1800bd9f0` |
| RTSPClient::getStream | `0x180185bb0` |
| RTSPClient::setStreamSecurityKey | `0x1801871f0` (code continues through `0x180187489` in unwind fragments) |
| createRTSPCamera | `0x180168ec0` |

`analysis/stream-rtspget-annotated.asm` and `analysis/stream-rtspkey-annotated.asm` preserve additional instruction evidence. The RTSP client identifies itself as `Rtsp Client/2.0 HSWX`; it configures proprietary stream security, so generic FFmpeg compatibility cannot be assumed merely from an `rtsp://` scheme.

## Remaining validation

1. Recover and verify consumer REST auth, region selection, actual device media fields and credentials.
2. Validate the recovered negotiation JSON and the device-specific defaults against authorized account traffic; the static payload construction is now fully recovered.
3. Verify that the official SDK can execute inside WKWebView with its worker/WASM/audio requirements and connect to the returned relay URL; public browser compatibility is not proof of that embedding.
4. Prove video/audio rendering for an actual authorized camera, with the device's normal encryption mode.
5. Handle device-key errors, expired/limited stream URLs, offline cameras, and session cleanup.

No end-to-end success has been established.
