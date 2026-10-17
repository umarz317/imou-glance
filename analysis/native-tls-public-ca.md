# Shipped public certificate resources and consumers

This is an offline investigation of the supplied Windows installer. No live
camera endpoint, account credential, session database, or iPad app was read.
No application code or trust configuration was changed.

## Certificate inventory

`native-tls-ca-inventory.json` records every certificate's source PEM,
zero-based position, subject, issuer, validity dates, DER SHA256, and SPKI
SHA256. The bundle contains14 certificate entries:

- `installer/bin/CA/Ims_Root_CA.pem`: one self-signed Imou Root CA,
  Huacheng, valid2024-09-29 to2064-09-19. DER SHA256:
  `f55893bff2466e78d3b18179728a43e3b5cd127a5c0a3d57154fa71bb25fa53d`.
- `installer/bin/CA/root_ca.pem`: Dahua Subordinate CA followed by the
  self-signed Dahua Root CA. Root DER SHA256:
  `3139b185b078ae882ea65a8cbeeaf17aad1a04f6712c3c28fa18240f8b8588dd`.
- `installer/bin/CA/cacert.pem`:11 entries, including public GlobalSign,
  VeriSign, GoDaddy, Amazon, and DigiCert roots, one repeated GlobalSign R3,
  and a self-signed `General Root CA` valid2019-2059. General Root DER SHA256:
  `f1fe6954bf72c3bfabf5ec863cd9928679934ff255ec5c6e17ad2d55e8bb5756`.

The files contain public certificates. Their presence is not evidence that
any particular live relay certificate chains to them. Inspecting only the
first PEM certificate would miss the Dahua root and General Root CA.

## Exact application call connections

EXE function `0x14053c3e0` builds a vector of certificate paths rooted at
`QCoreApplication::applicationDirPath`. Its three explicit fallbacks are
`CA/cacert.pem` at `0x14053c6d6`, `CA/Ims_Root_CA.pem` at
`0x14053c7ab`, and `CA/root_ca.pem` at `0x14053c880`. An alternate directory
scan exists behind its build/configuration condition.

Caller `0x1401ea1d0` receives that vector at `0x1401ea30a` and stores it in
`LogicParam_t+0x80` at `0x1401ea327`. It calls `LCLogic::Init` at
`0x1401ea675`. Export thunk `0x18000795f` reaches `0x1802dcc90`, which
forwards into `LCLogicImpl::Init` (thunk `0x180003693`, body
`0x1802ef680`). That body copies the vector into `LCLogicImpl+0x3c8` at
`0x1802ef7ac`.

`LCLogicImpl::GetPemPath` is export thunk `0x1800030ee`, body
`0x1802f19e0`. The body copies vector `+0x3c8`. Its three recovered direct
call sites establish these uses:

1. `0x18022e36f`, account REST initialization.
2. `0x1801fde5b`, cloud M3U playlist download (function logs identify M3U
   download at `0x1801fe7ca`, `0x1801fee25`).
3. `0x180243e86`, SDK REST initialization. The caller serializes the
   paths as a JSON array (`0x180243f97..0x180243fd8`), stores its string
   pointer in `LCSDK_RestApiParameter_t+0x80` at `0x180243fec`, and calls
   `LCSDK_Api::initRestApi` at `0x180244066`. SDK export body
   `0x1800a3610` copies that input field into SDK config `+0x278`
   (`0x1800a3857..0x1800a3871`).

A second EXE consumer calls path-vector builder `0x14053c3e0` at
`0x1401ec1cd` and passes the vector into `LCRequest::updateRequestInfo`
at `0x1401ec37b`. This is the app's request client, not proof of raw relay
TLS socket trust.

Separate EXE helper `0x14053c980` returns `CA/root_ca.pem` (or a test path
when explicitly configured). Its caller at `0x1405c3a70` places the result
in MQTT JSON field `pemPath` at `0x1405c3aac`. It is therefore not evidence
that the media relay socket uses that CA.

## Media TLS distinction and limit

The separate socket investigator recovered the HTTP media path:
`CHttpClientSessionImpl::init_internal` at `0x1804ec690` constructs an
isolated `CSslAsyncStream` at `0x1804ecc13`. It calls
`CSslAsyncStream::SetPemPath` (`0x180472030`) only when its optional extra
PEM pointer is nonnull (`0x1804ecce6`), then connects at `0x1804ecda4`.
The constructor clears its state, including verification flags, CA object,
and SNI. No shared SDK REST CA store was read on the recovered path.

The recovered evidence therefore **does not establish which bundled public
CA, if any, signs the live camera relay**. It also does not justify copying
the native default verification behavior. To use an exact bundled vendor
anchor securely, first compare the actual peer chain against this manifest,
then retain normal hostname, validity, and chain evaluation. A leaf presented
by a failed connection must not become a new trust anchor merely because it
was observed. Client-certificate or TLS-PSK requirements have not been
established by these CA consumers.

## Saved original-byte records

The bounded records are in `installer/native-tls-ca-init.asm`,
`installer/native-tls-ca-consumer-{one,two,three}.asm`,
`installer/native-tls-lclogic-{init,impl-init}.asm`,
`installer/native-tls-ca-{rest,user,other}-caller.asm`, and
`installer/native-tls-sdk-rest-init.asm`. The socket investigator's separate
record is `stream-native-http-tls-init-annotated.asm`.

No REA or SwiftPM process was started in this follow-up.
