# Native HTTP credentials and RTP handling

The native evidence in this report comes from static bytes in the supplied
installer. The final section also describes the corresponding transport
implementation. This report contains no live account values, camera
credentials, tokens, stream URLs, or camera footage.

## Camera credentials reach HTTP authorization

LCBaseLogic `VideoPlayer::OnRequestOpenVideo` at `0x18027be90` constructs
`tagOrgDevice` at stack `rsp+0xb70` (call `0x18027bffd`), then retrieves the
device through virtual slot `+0x3e0` at `0x18027c093`.

The `LCSDK_VideoPlay::playRTStream` calls at `0x18027d4d1` and
`0x18027d66e` receive PSK, camera username, and plaintext camera password in
that order. Caller stack `+0x30` points at `rsp+0xcb8`, which is device
`+0x148`; stack `+0x38` points at `rsp+0xcf8`, which is device `+0x188`.
The static format at `0x180394b78` names them `strPSK`, `strUsername`,
`strPassword` and agrees with the argument ordering.

`parseDeviceInfo` stores the wire `deviceUsername` at device `+0x128` and
unconditionally calls `AesDecryptDeviceUserInfo(serial, wire)` into device
`+0x148`. The JSON username therefore requires the legacy device-info AES
unwrap before HTTP authorization; sending its ciphertext would be incorrect.
Existing canonical parse evidence:
`ev_785bbea089787b2a64e3d7689ee08241c2309d3074bbb8a7864240cc7ba4f316`.

In StreamPCSDK, public `playRTStream` at `0x1800e96e0` forwards the username
and password through `VideoPlay_Inside::start` at `0x1800ee420`. The latter
copies them to playback parameters `+0x50` and `+0x70` at `0x1800ee6f3`
and `0x1800ee70c`. `doPlayDHHTTPStream` at `0x1800f80f0` uses those fields
as the HTTP username/password with `isAuth=1`. These are camera credentials,
not the consumer account UUID or token.

## Remote WSSE differs from local SHA1 WSSE

`CHttpClientWrapper::set_config_authorization` is at `0x1804fd8b0`.
Its input struct begins with username pointer `+0`, password pointer `+8`,
enabled flag `+0x10`, realm serial `+0x18`, selector byte `+0x28`, and
additional auth serial `+0x40`. The separate HTTP worker traced selector1
for nonloopback remote connections, selector0 for local connections.

The converted structure starts at local `rbp+0x20`. Its `+0x48` and `+0x68`
strings are distinct:

- For selector1 and nonnull input `+0x40`, `0x1804fde33..0x1804fde70`
  hashes `username + ":Login to "` using SHA256 and stores the **32 raw
  digest bytes** at converted `+0x48`. There is no hex conversion in this
  branch. Helper `0x1802a7620` initializes standard SHA256 state constants,
  updates using the explicit string length, and writes32bytes.
- Independently, nonnull input `+0x18` creates realm `"Login to " + serial`
  (`0x1804fda64..0x1804fda90`). Helper `0x180545a10` builds
  `username + ":" + realm + ":" + password`, hashes through
  `0x1805467e0`, then the converter uppercases its hex output at
  `0x1804fdcfc` and stores it at converted `+0x68`.
- The hex helper writes64 lowercase hex characters using `%02x` at
  `0x180a8c4f0`; the converter's explicit `toupper` makes the stored
  SHA256 HA1 uppercase.

`CHttpClientSessionImpl::setAuthrization` at `0x1804f36d0` checks selector
at converted `+0xa8`. When1, it explicitly sets authentication type8 to
`HMAC-SHA256` (`0x1804f37a0..0x1804f3840`). `CWSSEAuthClient::setAuthInfo`
at `0x18058f1f0` copies type5 into object `+0x48`, type7 into `+0x68`,
and type8 into `+0xc8` using length-preserving std::string copy; no further
hashing occurs in the setter. Its jump table is at `0x18058f320`.

`CWSSEAuthClient::getAuthorization` at `0x18058dc00` dispatches
`HMAC-SHA256` to `0x18058e860` and the default branch to SHA1 routine
`0x18058dcf0`. **The SHA1 branch is not the remote selector1 algorithm.**
The separate HTTP worker owns the remote HMAC routine and final wire headers.

## Interleaved RTP framing and depacketization

`CHttpRtpSeparator::get_packet_rtp_private` at `0x18053e3f0` sees `$`,
reads the channel byte and network-order16-bit length, then collects the
**entire** `4 + length` packet (`0x18053e700..0x18053e7d7`). The separated
packet retains its interleaving prefix. Partial packet bytes are retained
until complete. The alternate pre-RTP metadata path looks for header text
`Private-Length` and its terminator; this is separate from an RTP packet.

The later `CStreamDecRtp::put_packet` at `0x18064d000` detects `$`, reads
BE16 length, and passes `data+4,length` to the RTP frame parser at
`0x18064d15f..0x18064d1eb`. Its special encoding58 (`0x3a`) raw mode
calls `CRtp2Frame::PutPacketToRaw` at `0x180687370`; other types invoke
`CRtp2Frame::PutPacket` at `0x180688270` through the frame-parser vtable.

The actual RTP-header helper is `0x18068b5f0`. It computes:

```
headerLength = 12 + 4 * (rtp[0] & 15)
if rtp[0] & 0x10 != 0:
    headerLength += 4 + 4 * bigEndian16(rtp[headerLength+2...])
paddingLength = rtp[0] & 0x20 != 0 ? rtp.last : 0
payload = rtp[headerLength ..< rtp.count-paddingLength]
```

A replacement implementation must check bounds before every read, validate
RTP version2, require positive payload length, and reject impossible padding.
Those are input-validation requirements; the original helper is less strict.
Do not remove a fixed12bytes: CSRCs, extension words, and padding change the
payload range. `insert_packet` at `0x18068a230` uses this computed offset and
padding. It recognizes a network-order `0xabac` extension profile at
`0x18068a402` and reads its optional vendor timestamp.

`CRtp2Frame` then handles codecs differently. The dispatcher at
`0x18068a620` maps encoding58 to `0x1806c3d20`, which copies the payload
pointer and length unchanged for each packet. Encoding1/8 use a separate
codec-specific reassembler. Function `0x18068b330` recognizes the `DHAV`
magic at the payload start for encoding9 and55 (`0x37`). Thus merely
stripping RTP headers does not reconstruct every possible codec. In
particular, ordinary H264 fragmented NAL packets need their codec parser;
static evidence alone does not establish the actual camera's payload type.

The H5 worker separately tested the actual shipped WASM parser with
synthetic valid H264: AnnexB produced transcode callbacks, while raw RTP and
interleaved variants produced none. That is an independent runtime fixture,
not validation of the user's camera. Trying the SDK's supported `.xav`
transport with its own native framing can avoid this RTP conversion layer.

## Reproducible bounded records

`installer/native-http-credential-rtp-ranges.json` records binary SHA256,
original-byte range hashes, and disassembly paths for the converter, setter,
auth dispatch, SHA256 helpers, RTP header helper, RTP insert, and interleaved
consumer. Additional existing assembly records are named
`stream-native-http-*` and `stream-native-rtpxav-*` in `analysis/`.

No REA process or SwiftPM process was started for this follow-up. Original
bytes were read using the system LLVM disassembler; existing REA evidence
was reused for the device-info parser.

## Bounded DHAV-only transport adapter

Both encoding9 and55 select the same raw payload alias routine
`0x1806c3d20` through the `0x18068a620` jump table. This routine simply
sets output pointer `+0x430` to extracted RTP payload `+0x440` and output
length `+0x438` to payload length `+0x448`, following the packet-list next
pointer. It adds no NAL, container, or private header.

The earlier recommendation to lock to the first DHAV packet's payload type
was incorrect. `CRtp2Frame::PutPacket` at `0x180688270` checks the expected
RTP payload type at `0x18068846a..0x1806884a7`, but explicitly permits a
mismatch for encoding55 at `0x1806884ad..0x1806884bc` and encoding9 at
`0x1806884c2..0x1806884d1`. A valid DHAV header therefore does not identify
the video track, and private payload-type changes must not automatically
discard media. Audio can also be carried as DHAV; the observed SDP mapping
and independent sources are recorded in [native-sdp-framing.md](native-sdp-framing.md).

Sequence loss is recoverable in the native parser. The 16-bit sequence delta
is checked at `0x18068865c..0x180688678`; duplicates have an early-return
path at `0x18068868e..0x1806886be`. The loss path can recognize a new private
boundary through helper `0x18068b330` (called at `0x180688710`), invoke
`seq_disorder` at `0x18068873e`, and reset queued frame state at
`0x180688753`. The reset function clears the queued-packet count at
`0x180687fee..0x180687ff3` and resets the list head at
`0x180688002..0x18068800b`. Marker-bit processing calls frame assembly at
`0x180688f83..0x180688fa7`. These branches establish recovery rather than a
fatal connection error; they do not establish every native recovery policy.

The Swift adapter now maintains separate sequence and frame-assembly state
per interleaved channel and SSRC, without locking a source to its first PT.
It emits only complete DHAV frames, preserving their bytes unchanged and
validating each header checksum and declared length. A forward sequence gap
discards that source's incomplete frame and resumes at a valid DHAV boundary;
duplicate and stale packets are suppressed. Fragmented headers and multiple
frames in one payload are supported. Up to eight sources each retain at most
one incomplete frame, with a 5 MiB frame limit and 40 MiB aggregate retained
assembly bound. No new trailer constraint is imposed. This remains a
DHAV-only adapter: ordinary H264 FU/STAP packets require their codec parser.

The earlier encoding58 branch is controlled by `SetRtpNonstandard`, not by
the `.rtpxav` extension alone: `CTransformat::setOption` at
`0x1805f1810` recognizes that option at `0x1805f196b` and writes its boolean
to `+0x29d` at `0x1805f1a33`. `CTransformatRtpRaw::initParserParam` at
`0x180657370` turns that flag into encoding58 plus its raw flag
(`0x180657b43..0x180657b7c`). Without it, source packing kind5 maps to
encoding55 or9 at `0x180657ae0..0x180657b18`. This corrects any inference
that `.rtpxav` universally means encoding58.
