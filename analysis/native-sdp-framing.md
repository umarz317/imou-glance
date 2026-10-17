# Native SDP prefix framing

Target: `analysis/installer/bin/StreamPCSDKmd.dll`, SHA-256
`abaa4cb9b280ac042e32f65ab93d591e73ca25b8ab668f6b0bc5b39a069daa9a`.
Addresses below are Windows virtual addresses in that binary. This follow-up
reuses the retained native assembly evidence and bounded original-byte
disassembly; it does not execute Windows or inspect account secrets.

## Static observations

`CHttpRtpSeparator::get_packet_rtp_private` starts at `0x18053e3f0`.
Its textual-control branch distinguishes an HTTP/SDP record from the following
interleaved RTP bytes:

- At `0x18053e569` it compares the first byte with `$` (`0x24`); a match
  branches to the RTP path at `0x18053e700`.
- Otherwise, `0x18053e573..0x18053e586` searches for four bytes at
  `0x1809c5ce8`. Reading the original public binary confirms these bytes are
  `\r\n\r\n`.
- `0x18053e59f..0x18053e5af` searches the preceding header bytes for
  `Private-Length`, whose literal is at `0x1809c5cf0`. The numeric parse result
  is retained in `r15d` at `0x18053e5dd`; a negative result is rejected.
- `0x18053e5f1..0x18053e605` computes the complete control-record length as
  header bytes before the delimiter + 4 + Private-Length. It rejects a negative
  total or a total exceeding `0x8000` (32 KiB).
- `0x18053e60b..0x18053e613` waits until that complete record is available.
  `0x18053e693` marks the resulting record with channel `-1`, and
  `0x18053e6d1..0x18053e6d8` advances the input pointer and subtracts the exact
  record length. This is explicit length framing, not a search for the first
  `$` inside arbitrary SDP text.
- The RTP branch at `0x18053e70a..0x18053e71d` reads the interleaved channel
  byte, a network-order 16-bit payload length, and adds the four-byte `$`
  envelope size.

Retained evidence: `analysis/stream-native-rtpxav-frame-annotated.asm` and
`analysis/stream-native-rtpxav-separate-annotated.asm`.

`CHttpClientSessionImpl::dealResponse` handles the SDP separately from media:

- `0x1804e6db2..0x1804e6dd6` reads the `Private-Type` field. The referenced
  literal at `0x1809b24f8` is `Private-Type`, not `Content-Type`.
- `0x1804e6ef6..0x1804e6f15` compares its value with the 15-byte literal
  `application/sdp` at `0x1809b3088`.
- On that match, `0x1804e6f1b..0x1804e6f25` invokes
  `CHttpClientSessionImpl::getMsgBody` at `0x1804e9f80`.
- `getMsgBody` searches the already separated control record for
  `\r\n\r\n` at `0x1804e9fbe..0x1804e9fd5`, then extracts the substring after
  the delimiter at `0x1804ea096..0x1804ea0a8`. Its name is confirmed by the
  diagnostic literal referenced at `0x1804ea02a`.
- The separate SDP string becomes the third argument to `config_media` at
  `0x1804e709d..0x1804e70b3`. `config_media` passes it to the SDP parser at
  `0x1804e4df4..0x1804e4dfe`; its independent Content-Type lookup occurs at
  `0x1804e4ea3..0x1804e4ec3`. The `-rtpxav` check at
  `0x1804e5016..0x1804e502d` selects the private RTP separator, constructed at
  `0x1804e5057`.

Retained evidence: `analysis/stream-native-http-flag-context-annotated.asm` and
`analysis/stream-native-http-framing-selection-annotated.asm`. The focused
`dealResponse` and `getMsgBody` ranges above were additionally read from the
original binary with `llvm-objdump` during this follow-up.

## Runtime corroboration and implementation implication

The coordinating agent reported these redacted metadata observations from the
authorized Imou Peek connection: HTTP 200; Content-Type `video/e-rtpxav`;
Private-Type `application/sdp`; Private-Length 583; KeepLive-Time 30; no
Content-Length or Transfer-Encoding. The first 583 body bytes are SDP, followed
immediately by `$`-framed RTP; the first DHAV marker is at body offset 599.
This worker did not inspect the live connection or store the SDP contents.

The implementation should consume the explicitly declared private SDP prefix
before handing subsequent body bytes to the RTP framer. It must preserve
fragmentation across reads, reject conflicting or invalid length fields, and
bound the prefix. Ordinary HTTP Content-Length semantics must remain separate
from Private-Length: the latter describes the initial private control payload,
not the entire live stream. No content-type parameter or SDP line-scan boundary
is needed for the observed response.

This explains the observed first-packet rejection after successful TLS and
HTTP. It does not by itself establish successful video decryption, decoding,
or changing camera frames.

## Runtime media mapping and sequence recovery

Subsequent redacted SDP inspection by the coordinating agent identified
video PT98 as `H265/90000`, audio PT97 as `MPEG4-GENERIC/16000`, and
application PT100 as `stream-assist-frame/90000`. The first DHAV packet was
audio PT97, so selecting the first DHAV payload type permanently excluded
video. A bounded runtime packet ring confirmed that audio PT97 and video
PT98 have distinct SSRCs and independent sequence spaces. The coordinating
agent reported source aliases only; this record contains no SSRC values or
full SDP.

A separate capture established a genuine forward video sequence jump of
137 on the same source after a valid DHAV header. The adapter consequently
needs both independent channel+SSRC assembly and incomplete-frame recovery;
merely removing PT filtering cannot resolve all discontinuities. The native
private-encoding PT exemptions and recoverable sequence-loss branches are
documented in [native-http-credentials-and-rtp.md](native-http-credentials-and-rtp.md).
Focused synthetic framing tests cover audio arriving first, independent
sources, PT changes, gap recovery, duplicate suppression, fragmented headers,
and multiple DHAV frames per RTP payload. These tests do not establish
long-duration camera playback.
