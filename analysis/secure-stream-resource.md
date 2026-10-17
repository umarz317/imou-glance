# Secure stream resource format

Static SDK artifact: `StreamPCSDKmd.dll`, SHA256 `abaa4cb9b280ac042e32f65ab93d591e73ca25b8ab668f6b0bc5b39a069daa9a`, image base `0x180000000`.

The Windows stream URL parser explicitly supports **both `rtsp://` and `rtsps://`**. Its `rtsps://` literal is at raw file offset `0x9c2170` / VA `0x1809c3b70`, bytes `72 74 73 70 73 3a 2f 2f 00`. The common `rtsp://` literal is raw `0x889e40` / VA `0x18088b840`.

`Basic::StreamApp::CRtspUrlParser::getContentFromUrl` actual VA `0x18054d320` searches `rtsp://` using length 7 (`0x18054d3de`–`0x18054d402`). If absent it searches `rtsps://` using length 8 (`0x18054d41a`–`0x18054d442`). Both flow through the same authority and path extraction code starting `0x18054d449`, which removes the matched prefix length. There is no branch-specific host or port conversion here. Instruction evidence: `stream-native-tls-parser-annotated.asm`.

The URL helper at `0x180533fc0` independently supports both schemes, first checking `rtsps://` length 8 (`0x180534069`–`0x180534098`), otherwise `rtsp://` length 7 (`0x1805340a8`–`0x1805340d4`), joining common parsing at `0x1805340db`. Evidence: `stream-native-url-scheme-annotated.asm`. Another helper `0x18054b670` accepts either prefix before common processing (`stream-native-url-prefix-annotated.asm`).

The native caller treats TLS as explicit configuration as well as accepting the secure scheme. `createRTSPCamera` reads JSON `isTls` and stores it at camera parameter offset `+0x110` (`0x1801692aa`–`0x1801692c1`, existing `stream-create-camera-annotated.asm`). The GetRealTransferStreamUrl builder selects `data.tls_resource` when its TLS flag is true and copies that string into the output; the caller returns it without a `rtsps` → `rtsp` conversion. Thus prefix conversion is an adapter requirement for the browser SDK, not something the Windows producer demonstrates.

The bundled official browser SDK recognizes only `rtsp://` in the carrier string: at UTF-8 byte offset 1429877 it removes that prefix, uses the first slash-delimited component as authority, then constructs `ws[s]://<authority>`. For RTSV it connects `/httpprivateoverwebsocket` and forwards the original resource component as the private request. This file contains no `rtsps://` handler. The app wrapper already forces WSS, preserving transport TLS independently of the carrier prefix.

Supported adapter: accept a valid `rtsps://` secure resource, preserve **every byte after the prefix** (including authority, explicit port, path and query), and supply `rtsp://` plus that unchanged suffix to the browser SDK while retaining its WSS transport. Accept existing `rtsp://` values from the `tls_resource` field without modifying their suffix. Do not switch to `resource`, infer a different port, rebuild/re-encode the URL, or remove encryption parameters. This preserves the scheme-independent native parsing semantics with browser transport security.

The actual failed account resource was not read by this worker. Its scheme being `rtsps` remains a hypothesis until redacted metadata confirms it. This is static compatibility evidence, not a successful camera playback test.

## Follow-up: scheme-less diagnostic and RTSV parser

The UI's later “missing scheme” text is not enough to establish that the raw server value lacks a scheme. If it is computed from `URLComponents(string: resource)?.scheme`, a failure to parse any other URL component produces the same text. Determine a redacted scheme category directly from the raw prefix rather than logging the resource or asking the standards parser to process its opaque query.

The **consumer RTSP parser does reject an actually scheme-less input**. In `getContentFromUrl` (`0x18054d320`), if both scheme searches fail, the selected prefix stays empty. The subsequent DSL search (`0x18054d488` call to `0x1807bb3f0`) delegates to `0x1807bd070`, which rejects an empty search needle at `0x1807bd0a7`–`0x1807bd0aa`, returning `-1` at `0x1807bd0f4`. The caller checks the negative result at `0x18054d48d` and fails. Evidence: `stream-native-content-find.asm`. Public `CRtspUrlParser::parseUrl` at `0x18054dd70` calls this content extraction at `0x18054ddb0` and propagates false. Evidence: `stream-native-parseurl-entry-annotated.asm`.

The previously listed helper at `0x180533fc0` is **CUrlFilter::default_url_map**, a server-side mapper. Its scheme checks are corroborative syntax evidence, not the consumer parser's entry point. Its logs identify it at `0x180534825`.

The distinct **RTSV HTTP-private transport** uses `Basic::StreamPlayer::CStreamHttp::parseUrl` at `0x180493ce0`. It accepts `http://` length 7 (`0x180493d31`–`0x180493d60`) or `https://` length 8 (`0x180493d71`–`0x180493d99`), passes the chosen prefix to common parser `0x1804a2300` at `0x180493dbd`, and returns `-1` at `0x180493e20` if neither prefix is found. It does not prepend a scheme to a bare authority. Evidence: `stream-native-http-parseurl-annotated.asm`, strings raw `0x999d90` and `0x999d98`.

Those parsers alone do not establish a scheme-less relay path. The distinct RTSV camera factory below does. A malformed opaque query should not cause the whole resource to be mislabeled as lacking a scheme.

## Decisive RTSV factory: bare authority is intended

Root subsequently inspected only redacted metadata in our own running app under LLDB. Actual `tls_resource` is 178 bytes, contains no `://` separator, starts with a digit, has a valid authority when prefixed with `rtsp://`, has an explicit port, and contains no user information or control characters. No resource value, authority, query value, or credential was disclosed to this worker.

`Basic::LCCommon::createHttpCamera`, actual VA **`0x180167650`**, handles this exact form directly. Evidence: `stream-native-rtsv-factory-annotated.asm`.

1. Reads `httpCamera.url` as a string at `0x1801676ec`–`0x180167702`, local `rbp-0x70`.
2. For the ordinary camera path, checks it is nonempty at `0x180167ff0`–`0x180167ff7`.
3. Searches the first `:` starting at offset zero (`0x18016800b`–`0x18016801e`). Copies the substring **before that colon**, with no scheme stripping, into camera host field `+0xa0` (`0x180168031`–`0x180168057`).
4. Locates the first `/`, then takes characters after `:` and before `/`; calls `atoi` at `0x180168172` and stores the explicit port in camera field `+0xc0` at `0x180168178`.
5. Copies the **entire substring from the first `/` through the end** into camera resource field `+0x80` at `0x180168190`–`0x1801681f8`. There is no URL decoding, query reconstruction, or percent escaping here.
6. Reads independent JSON `isTls` and stores camera bool `+0x1e0` at `0x180168211`–`0x180168228`.

This factory expects `host:port/resource` rather than a standards URL. The RTSP and CStreamHttp standalone URL parser rejections above do not apply to this transport configuration path. `CDHHTTPClient::getStream` (actual `0x1801886b0`, `stream-native-rtsv-client-annotated.asm`) uses the already-separated camera host, port, resource and TLS bool. At `0x18018a1b8`–`0x18018a1c4` it maps the camera TLS bool to socket type, then passes that type to client init at `0x18018a257`–`0x18018a267`; no scheme is needed to choose secure transport.

The correct bundled-browser adapter may therefore prepend **`rtsp://`** to the observed valid bare authority/resource carrier, retain the explicit port and every suffix byte, and always use WSS. This is now backed by both the actual redacted response shape and the exact native factory rather than a speculative URL repair.

The supplied resource has two `/` characters. Vendor JS's `.split('/')[1]` extraction needs care: it truncates a further slash in either the path or opaque query. Native factory preservation is `resource.substring(firstSlash)`, so the browser bridge must likewise preserve the full remainder. Peer cloud worker is checking that adapter limitation.
