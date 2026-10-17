# Native secure HTTP media protocol evidence

Static analysis only. No credential or media requests were made by this worker. Binary: `analysis/installer/bin/StreamPCSDKmd.dll`, SHA256 `abaa4cb9b280ac042e32f65ab93d591e73ca25b8ab668f6b0bc5b39a069daa9a`, image base `0x180000000`. Text VA to raw offset subtracts `0x180000c00`. Addresses below are virtual.

## URL and TLS

`Basic::LCCommon::createHttpCamera` (0x180167650) accepts bare `host:port/path?query`: first colon splits host; first slash terminates decimal port; entire first-slash suffix is copied unchanged. `isTls` is a separate JSON bool and camera+0x1e0 field (0x180168211). Thus a bare `tls_resource` is native-supported. See `secure-stream-resource.md` and `stream-native-rtsv-factory-annotated.asm`.

## Device credential provenance

`doPlayDHHTTPStream` 0x1800f80f0 config JSON takes username from Inside+0x50 (0x1800f8185), password from Inside+0x70 (0x1800f81c5), and isAuth=1 (0x1800f8278). Independent native_ui trace maps those values from OnRequestOpenVideo orgDevice+0x148 deviceUsername and +0x188 plaintext device password through public playRTStream. This is not account UUID/token authentication.

## Remote WSSE V2 (correction to initial local SHA1 branch)

`CDHHTTPClient::getStream` 0x1801886b0 builds raw config type2 length0x58. Remote flag at raw+0x28 is 1 (0x18018991b); local loopback is 0. Remote Created uses UTC `%Y%m%dT%H%M%SZ`. `CHttpClientSessionImpl::setAuthrization` (0x1804f36d0) uses converted selector+0xa8==1 to set auth type8 to `HMAC-SHA256` at 0x1804f3814..3840. `CWSSEAuthClient::getAuthorization` dispatches to `getAuthorizationHmacSha256` 0x18058e860, bypassing local legacy SHA1 function 0x18058dcf0.

Converted config+0x48 (auth object+0x48) is a **32-byte raw SHA256 key**. The remote converter branch 0x1804fde33..4fdf76 builds `username + ":Login to "` then calls raw SHA256 helper 0x1802a7620 and copies exactly32 bytes. It does not append serial/password in this remote branch. The separate config+0x68 uppercase SHA256-HA1 (username:Login to serial:password) is not consumed by the V2 digest path. Independent trace by native_ui confirms those converter branches. See `stream-native-http-auth-convert-tail-annotated.asm` (initial bytes start midinstruction; correct aligned branch begins 0x1804fde33), and peer's full aligned dump for authoritative branch entry.

`getAuthorizationHmacSha256` requires nonempty username, Created, URL and key.length==32 (0x18058e8a9..e8d2). Message construction (0x18058e960..ea96) concatenates auth object+0xa8 **URL**, object+0xe8 **Content**, nonce ASCII, Created ASCII without separators. Nonce comes from 0x18058dab0, a 32-character ASCII MD5 hex nonce. It is used directly as ASCII, not Base64-decoded. At 0x18058ebb6 the OpenSSL HMAC helper 0x1802d6e40 receives EVP_sha256 from 0x1802d5fc0, keyptr, keylen32, messageptr+length. Digest32 is Base64 encoded at 0x18058ecc7.

First GET Content is empty: auth constructor 0x18058d8e0 initializes object+0xe8 empty at0x18058d9a2..9b4, and send_first_cmd sets only type2 URL at0x1804f29aa. Setter type9 would populate Content; type2 maps object+0xa8. Therefore first-request formula is:

```text
K = SHA256_raw(UTF8(username + ":Login to "))
D = Base64(HMAC-SHA256(key: K, message: UTF8(target + nonce + created)))
WSSE: UsernameToken Username="<username>", PasswordDigest="<D>", Nonce="<nonce>", Created="<created>"
Authorization: WSSE profile="UsernameTokenV2"
```

Exact headers constructed 0x18058edbb..58eec4 and 0x18058efd9..58f010. No LightweightDigest in remote V2. Raw evidence `stream-native-http-wsse-hmac-annotated.asm`, helper `stream-native-wsse-hmac-helper-annotated.asm`, constructor `stream-native-wsse-init-annotated.asm`, dispatch `stream-native-http-auth-setup-annotated.asm`.

### Native target adjustment

The ordinary first request appends `method=0` to the raw resource (using & when query exists, ? otherwise), and signs that adjusted target. send_first_cmd copies session+0x360 resource (0x1804f28d0), calls insert_track then insert_method enum0 (0x1804f2916..2931), then sets URL auth field. send_request independently makes the same copy (0x1804f33a4), insert_track0x1804f33c3, insert_method0x1804f3437, before serializing request. `insert_method` 0x1804ed220 appends the delimiter then literal `method=0` at0x1804ed671. `insert_track`0x1804ed770 only appends trackID for mediaType3, nonempty SDP and track !=0x100. First ctor track=0x100 at0x1804e2b6a.

There is a special session+0x6c0 mode skipping method insertion and using HTTP selector7. This flag initializes false at0x1804e2c18 and is cleared on reset/dealResponse; no setter-to-true found in this base-class path. Do not claim this special mode applies to the actual account without runtime evidence. `stream-native-http-request-annotated.asm`, `stream-native-http-send-annotated.asm`, `stream-native-http-url-auth-adjust-annotated.asm`.

Other ordinary headers in send_request: `User-Agent: Http Stream Client/1.0`, `Connection: keep-alive`, `Cseq: <number>`, **`Accpet-Sdp: Private`** (native spelling). All returned WSSE header pairs are actually copied into the request (0x1804f2aa0..2ab2).

## Response framing — confirmed bounds, depacketization pending

`config_media`0x1804e4d00 selects separator by response Content-Type: contains `-xav` -> private separator enum1; contains `-rtpxav` -> CHttpRtpSeparator constructor0x18053e340, enum5 at0x1804e50cc. Observe Content-Type, not path alone.

For rtpxav, `CHttpRtpSeparator::get_packet_rtp_private`0x18053e3f0 handles ASCII control messages and `$` interleaved packets. At0x18053e700 it reads channel byte1 and **BE16** payload length bytes2..3 via ntohs at0x18053e714; total4+length. It copies the **entire4-byte envelope and RTP packet** into downstream buffer. This is NOT vendor browser RTSV dA's 6-byte envelope ($+channel+BE32 length). Do not pass bytes after4 directly to the WASM private-video decoder until RTP/private depacketization is proven. Peer native_ui is tracing downstream media_session transforms.

Raw dumps: `stream-native-http-framing-selection-annotated.asm`, `stream-native-rtpxav-frame-annotated.asm`, `stream-native-rtpxav-separate-annotated.asm`, `stream-native-rtpxav-callback-annotated.asm`.

## Minimal private-XAV compatibility probe (not validated)

Native supports `/live/realmonitor.xav` as an explicit constructed endpoint: getRestOptional0x1800d1c90 template references0x1800d257f,0x1800d26aa,0x1800d270b; SmartRTPlayer local HTTP template0x180124e74. SDK has no literal `realmonitor.rtpxav`, so no static proof of an automatic rewrite from the cloud's returned rtpxav path to xav or that this cloud relay accepts both paths.

If a bounded HTTPS probe changes only `/live/realmonitor.rtpxav` -> `/live/realmonitor.xav`, preserves all query fields, appends native `method=0` and signs that exact target with WSSE V2, then a successful observed `-xav` Content-Type gives a much simpler source-supported transport: **CHttpDhSeparator** constructor0x18053d880, get_packet_private0x18053dac0, branch0x18053dd41 reads `$`, channel byte1, BE32 length bytes2..5 via `ntohl`(Winsock ordinal14)0x18053dd54; advances input6 at0x18053ddbf and copies only payload downstream. This matches official browser SDK dA's6-byte RTSV private-XAV envelope. Raw `stream-native-xav-frame-annotated.asm`. Do not silently interpret `-rtpxav` response through this framer or claim server acceptance without observing it.
