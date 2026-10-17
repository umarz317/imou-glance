# Windows camera-stream evidence

Static inspection only. Nothing from the installer was executed and no camera/account traffic was generated. Paths are relative to `/Users/umar/Documents/ChatGPT/Imou`. Offsets below are hexadecimal **raw file offsets**, except explicitly marked PE export RVAs. Readable strings support hypotheses; they do not prove live server behavior or exact request JSON.

## Result

The Windows application uses a native proprietary streaming stack, `StreamPCSDKmd.dll`, with P2P-to-localhost proxy and MTS relay alternatives. RTSP and an HLS-like format exist, but the package does **not** establish that consumer cameras offer a plain AVPlayer-compatible cloud URL. Reconstructing or replacing this media layer is the main additional work after sign-in/device discovery. A macOS SDK may exist elsewhere, but this installer supplies Windows PE binaries and supplies no evidence of a macOS-compatible build.

## Identity and dependencies

`Version.ini` identifies app version 6.1.8, 64-bit. `StreamPCSDKmd.dll` is PE32+ x86-64, image base `0x180000000`, Windows GUI subsystem. `analysis/strings/StreamPCSDKmd.pe.txt` preserves its `objdump -p` import/export inventory.

| File under `analysis/installer/bin/` | SHA-256 |
|---|---|
| StreamPCSDKmd.dll | abaa4cb9b280ac042e32f65ab93d591e73ca25b8ab668f6b0bc5b39a069daa9a |
| LCBaseLogic.dll | 2c75495f9a8898338105f484f1deb922d8fa694c7a831f20377282b16f638b24 |
| lcplay.dll | 9b95395e4c3d96542d507d2cda826b7f4ff3ea3d113ff0d6a153df3475a2bc73 |
| dhnetsdk.dll | 7a09f58d983f52e244ea7364f3dd2e85a6e673224ec333c19526b12207a1b0ba |
| IoTClient.dll | d691a246cca3d3d6b197451036df0d5f3775b5ee99266f9a64ad8708e44dc1f8 |

The streaming DLL imports `IoTClient.dll` device-discovery methods, `MqttComponent.dll` including `mqtt_client_sync_request`, `lcplay.dll`, `dhnetsdk.dll`, FFmpeg-family `avcodec-60.dll`, `avutil-58.dll`, `swscale-7.dll`, `swresample-4.dll`, and Win32/Windows sockets/crypto/VC runtime libraries. Several `dhnetsdk.dll` imports are ordinal-only, so the current output does not name those specific calls.

Exported C++ methods include (RVAs):

- `LCSDK_Api::initRestApi` `0xa3610`, `loginRemoteServers` `0xa3970`, `setConfig` `0xa3a50`.
- `LCSDK_VideoPlay::initVideoPlay` `0xe8cc0`; mangled signature accepts an integer and `void *`, consistent with platform-specific rendering setup, but exact HWND semantics require disassembly/header evidence.
- `playLANRTStream` `0xe93a0`, `playRTStream` `0xe96e0`, `playDHRTStream` `0xe9b70`.
- `playCloudRecordStream` `0xeaf50`, `playCloudRecordStreamEx` `0xeb3a0`, `playLiveStream` `0xeb6c0`.
- `LCSDK_LoginManager::getNetSDKHandler` `0xb8a80`, `getP2PLinkType` `0xb8f80`.
- Crypter encrypt/decrypt/verification exports exist; this is more than a generic URL player.

## Live-stream routes and negotiation

All offsets in this section are in `StreamPCSDKmd.dll`:

| Raw offset | Evidence | Implication / limit |
|---|---|---|
| `0x871670` | `/pcs/v1/things.media.LoginStream` | Separate stream-server login operation, near `loginRemoteServersDetails`. |
| `0x8750d0` | `/pcs/v1/things.media.GetRealTransferStreamUrl` | Candidate live cloud relay URL negotiation operation. |
| `0x874dd8`–`0x8750d0` | `productId`, `deviceId`, `channelId`, `streamId`, `encrypt`, `RTSV1`, `windowNum`, `assistStream`, `skipAuth`, `imageSize`, `audioType`, `timeLimit`, `videoLimit`, bind IDs, `targetDevice` | Candidate request vocabulary adjacent to the route; exact shape/types not recovered. |
| `0x875360`, `0x875378` | `tls_resource`, `resource` | Candidate response keys for relay resources. |
| `0x873ea0`, `0x873ed0` | `iot.control.SetService`, `iot.control.SetIotService` | MQTT/IoT alternative present in stream URL negotiation code. |
| `0x8766a0` | `getUrlAutomatic try p2p begin!` | P2P is attempted by automatic source selection. |
| `0x876a80` | `rtsp://127.0.0.1:%d/%s` | Local proxy URL constructed after P2P port success. A localhost URL is not a directly reusable remote camera address. |
| `0x876b50` | `0:P2P, 1:MTS,getUrlAutomatic>>m_streamMode:%d` | Explicit stream mode distinction. |
| `0x876c40` | `[StreamEncrypt] start getRealTransferStreamUrl sn=%s channel=%d encryptMode=%d` | MTS relay URL operation participates in encrypted-stream handling. |
| `0x876220` | `live/realmonitor.xav?pid=%s&device=%s&channel=%d&subtype=%d%s%s` | HTTP-family private media path template. |
| `0x8761c0`, `0x876260` | `&proto=Private3` | Proprietary protocol option. |
| `0x8775a0` | `/cam/realmonitor?pid=` | RTSP live path construction. |
| `0x88c8a0` | `rtsp://%s:%d/cam/realmonitor?channel=%d&subtype=%d&proto=Private3` | Complete RTSP template. |
| `0x88c868` | `http://%s:%d/live/realmonitor.xav?channel=%d&subtype=%d` | Complete HTTP private-media template. |
| `0x8a7290`, `0x8a7310` | `set config 0x95 encrypt failed`, `set config hhyencrypt failed` | RTSP client can apply additional stream decryption configuration. |

`LCBaseLogic.dll` device-detail parsing strings at `0x377bc0`–`0x377d50` and `0x378280`–`0x3783e0` include `mediaConfig`, `streamClarity`, `streamChannel`, `streamEncryModel`, `streamProtocol`, `wssekey`, `wssekeyNew`, `streamUrl`, `pullStreamModel`, `deviceAccount`, `deviceAccountNew`, `devicePassword`. These fields are candidates to preserve in native device models rather than discarding everything except camera name and serial number.

## HLS evidence and compatibility concern

`StreamPCSDKmd.dll` contains an HLS client and cloud playback implementation; `playLiveStream` also accepts an `LCSDK_HLS_TYPE`. This is evidence of HLS-family support, not proof of ordinary live HLS availability for a consumer account.

- `0x9e03e0`: `#EXTM3U`.
- `0x9e0418`: proprietary `#EXT-X-SDPINFO:`; `0x9e0648` reports failure if absent.
- `0x9e06a0`: proprietary `#EXT-X-SETUPINFO:`; `0x9e06b8` reports failure if absent.
- `0x9e0428`: `#EXT-X-PROTOCOLTYPE:`; `0x9e0440`: `#STREAM-HOST:`.
- `0x9e09d8`–`0x9e0a28`: keyframe/size/localtime extensions (`#EXT-X-IF`, `PF`, `ID`, `SIZE`, `LOCALTIME`).
- `0x9e2c08`: `download dav fail`; `0x9e2c38`: `download dav done`. Segment payloads can be DAV rather than ordinary MPEG-TS/fMP4.
- `0x899c90`–`0x899e70`: cloud player uses PSK, SDP and MIKEY exchange/decryption.
- `0x883468`, `0x883500`: AES-256 OFB and GCM stream-encryption modes.
- `0x8836e0`, `0x886ab8`: PBKDF2 key-generation messages reference device ID/device password.

No case-insensitive `webrtc` match was found in `analysis/strings/StreamPCSDKmd.dll.txt`. No macOS/Darwin/OS X library or native implementation was found in this Windows package. This absence does not establish that the service lacks WebRTC or a separate macOS SDK.

## Implementation implications and remaining questions

1. Preserve the full authorized device/channel media configuration returned after account login. Validate what actual `streamProtocol`, `streamEncryModel`, URL and account fields contain before choosing a player.
2. Recover the exact authenticated request construction and JSON shape around `GetRealTransferStreamUrl`, including stream server auth/token handling and MQTT versus REST branch selection.
3. Observe an authorized live session or obtain official cross-platform SDK headers/binaries to determine whether a particular camera/region exposes playable standard RTSP/HLS, private HTTP/DAV, or encrypted relay transport. Do not label generic AVPlayer playback complete based on the route strings.
4. A practical macOS player can use a standards-based media library if returned streams are standard. Private framing, encrypted stream variants and P2P transport require compatible implementation or vendor SDK support.
5. Local LAN RTSP is a useful separate fallback path but does not itself fulfill consumer Imou-account sign-in and remote camera viewing.

No request shape, credential encoding, successful login, live camera transport, hardware decode, or macOS runtime integration was validated by this static inspection.
