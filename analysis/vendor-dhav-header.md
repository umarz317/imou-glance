# Pinned vendor DHAV header and partial input

Artifact: `Sources/ImouMac/PlayerAssets/WasmLib/SingleThread/liblcplay.wasm`, SHA256 `d1c127b86345a01991639de38438bf7b0b9d2357b7f9f1b7ad661dbd19f2320a`. Public source provenance is recorded beside the asset. Addresses below are the WASM disassembly addresses reported by Xcode `llvm-objdump`.

`Basic::StreamParser::CDHAVStream` is identified by its RTTI name at linear-memory address `0x5bc0c`, typeinfo `0xb7afc`, and vtable `0xb7a68`. Its vtable slot 21 maps through table index 2915 to function 6508, header parser at `0x241976`. Slot 22 maps to function 6505 at `0x240e60`.

The basic DHAV wire layout is:

| Offset | Field | Evidence |
| --- | --- | --- |
| 0–3 | ASCII `DHAV` | Auto-detector function 6657 recognizes rolling constant `0x44484156`; CDHAV parser selects that family. |
| 12–15 | Total frame byte length, little-endian UInt32 | Function 6505 loads unaligned `i32.load 12` at `0x240f2c`. Function 6508 copies 24 header bytes to stack offset 40, then loads stack offset 52 at `0x241c2f`. WASM integer memory loads are little-endian. |
| 22 | Extended-header length, UInt8 | Function 6505 loads byte 22 at `0x240f25`; function 6508 loads copied byte at stack offset 62. |
| 23 | Header checksum | Sum of bytes 0 through 22, modulo 256. Function 6208 at `0x232a52` loops over 23 bytes; comparison appears at `0x241ac7`–`0x241aee`. |
| 24 onward | Extended header, then media payload | Payload begins at `24 + extensionLength`; function 6508 at `0x241e20` onward and `0x24202b`. |
| Last 8 bytes | ASCII `dhav`, then the same total length as little-endian UInt32 | Function 6501 at `0x240d4d` validates the final tag through function 1331 (`0x912df`) and compares its unaligned length at offset 4. Function 6508 does the same at `0x241d6b` onward. Other format variants have their own lower-case tail tags. |

The fixed header is **24 bytes**; the frame overhead is **32 + extensionLength** including the eight-byte tail. The parser calculates media payload length as `totalLength - extensionLength - 32`. A bounded basic-DHAV sanity check can buffer 24 bytes, validate magic/checksum and require `totalLength >= 32 + extensionLength` and a chosen upper limit. A nonempty-media requirement can use a strict greater-than comparison. The app's per-packet decoder limit is 5 MiB because the pinned worker allocates a fixed 5 MiB parser input array; this is stricter than the parser's own broader internal frame-length check.

The parser's ordinary header branch waits for at least 48 buffered bytes before continuing (`0x241a5d`), despite the fixed header itself being 24 bytes. That is buffering/lookahead behavior, not a 48-byte wire header. Do not reject a fragment merely because it contains less than the fixed header or because an RTP packet splits the magic/header.

## Actual isolated parser validation

An isolated macOS WKWebView initialized the unchanged actual WASM. A local harness generated 37 synthetic DHAV frames containing locally generated H.264 NAL units. Each synthetic frame used the above 24-byte header, length at byte 12, checksum, zero extension length and `dhav`/length tail. The complete fixture contained 31,486 bytes. No user/account/camera data or media network request was used.

The harness fed the identical fixture to `_PLAY_ParseStreamInit` / `_PLAY_ParseStream` with these chunk sizes:

| Chunk bytes | Transcode callbacks | Parser exceptions |
| --- | --- | --- |
| 31,486 | 37 | 0 |
| 1 | 37 | 0 |
| 3 | 37 | 0 |
| 7 | 37 | 0 |
| 23 | 37 | 0 |
| 1,500 | 37 | 0 |

Output: `PASS SYNTHETIC_DHAV_PARTIAL_CHUNK_PROBE_NO_NETWORK`.

This validates the basic header layout, parser buffering across split magic/header/body/tail, and the absence of a required RTSP metadata exchange for this DHAV parsing path. The callbacks were parser/transcode callbacks. The test does not establish actual-camera encryption compatibility or rendered live-video playback.
