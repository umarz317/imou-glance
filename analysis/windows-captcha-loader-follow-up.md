# Windows CAPTCHA loader follow-up

Static REA verification on 2026-10-17. No Windows process was run, account request
made, CAPTCHA solved, or credential read. The native REA session opened for this
check was closed.

## Target and scope

`analysis/installer/bin/LCCommon.dll`, SHA-256
`35fc0023f71864b663cdd7f3f31998b938638dff7950c9c99e26c792b325dae3`.
Provider: Ghidra 12.1.4. Existing raw-response/full-overload evidence in
`pcs-config.md` was read rather than rerun. Fresh records are retained in ignored
`pcs-captcha-loader-follow-up-evidence.json`.

## Observed behavior

The complete analyzed body of `LCGeeTestView::loadGeeTest` at `0x180008770`
(`0x180008770–0x180008c59`) creates exactly these mandatory JSON fields:

```json
{
  "captchaId": "<challenge captchaId>",
  "protocol": "https://",
  "language": "<caller language>",
  "nextWidth": "340px"
}
```

A true optional boolean additionally writes `captchaVendor:"geelab"`.
Fresh vendor-helper decompilation at `0x1800096f0` confirms that exact value.
No `apiServers`, `staticServers`, `region`, or account/authentication field
is written by this complete function. This is a bounded function observation,
not a claim that the remote JavaScript never creates other settings.

Evidence:
- Full loader dossier:
  `ev_5d0e9cc39098aa29f1266f881c0a4c92d3b3f203d296d14fff280e50be475c7a`.
- Vendor helper:
  `ev_41f1456d0a8e362e25b3aa65c66e0d689e4e12d97e335a02c4ea48a11fa8decd`.
- Earlier raw-response/full-overload observations:
  `ev_f9b8423ba8e33b1f2fe7b8d051f8de3ad2ad4469ec7b4b3e73c8c164ad159c74`,
  `ev_9c1a198d2943f4ee1f37efdc28874e09759e4c147571a5fb69e9238f69f307ee`.

The resulting JSON is concatenated with the caller-supplied page URL. The
existing EXE page helper evidence identifies the overseas page as
`https://pc.imoulife.com/h5-pc-base-v6/static/GeeTest.html?data=`; the existing
overseas caller does not set the optional vendor boolean. Native account,
usage, CAPTCHA metadata, and optional verification token are captured for the
later check request and are not appended as page configuration.

The view **uses LCCefWebView (Chromium Embedded Framework), not QWebEngine**.
The constructor `0x180008560` subclasses `LCCefWebView`, registers itself as
the JavaScript backend and sets the bound view ID to `LCGeeTest`.
For an HTTPS page the loader invokes `LCCefWebView::openUrl`; a separate
`IsLocalUrl` branch uses `openLocal`. Its string helper at `0x1800095f0`
supplies `#FFFFFF`, as does the local-URL helper at `0x1800094f0`. This is
consistent with a background-color argument, and is not a user-agent string.

Evidence:
- Constructor:
  `ev_e84599ba51cd13bd9d561f96ca907b7f46bfba863e883732d65639c8eaff794a`.
- Remote/local string helpers:
  `ev_a704a8cd9547e211f7635d868359634d9b17ee43da2ad3fc0bf0e14da791c8a3`,
  `ev_6b713af6d34d7007e4ff553f96443a58bfcecc907938145f02f3b72adc8ff4c2`.
- Complete 16-byte UTF-16 literal:
  `ev_e6392da51cd084563f10a6711cf3d43ebf4b230d3923ce4f5fcee5405d0415e5`.

The earlier bridge evidence remains applicable: `notifyGeeTestState` receives
`ready/result/close/fail/error`; `ready` invokes
`window.captchaObj.showCaptcha()`; a human-completed result is checked using
`/pcs/v1/common.validcode.CheckGeeTest4`, after which the native login retries.

## Unknowns and limits

This static pass did not establish the precise Chromium user agent, cookie
profile, request headers, or network requests produced at runtime by the
Windows client. It did not inspect the internals of `LCCefWebView.dll`.
The actual top-level HTTPS navigation supports the ordinary page-origin
interpretation, but runtime headers were not observed.

These binaries do not define the semantics of vendor error `-50106` in the
bounded loader. An empty defined-string search for `apiServers` and
`UserAgent` in `LCCommon.dll` is recorded, but does not prove their absence
from other libraries or the remote page. No error-specific fix should be
claimed from this native evidence alone.

## Official web bundle provider selection follow-up

The existing official web artifact
`analysis/web/app.b4abc392372cb3036dd7.js` has SHA-256
`f888b7d6fbeee33eb6a2b32ed40e1b79bf4090fa59aa6dd011225e0373aeb2ed`.
Focused text tracing found an explicit provider selector in Webpack module
`1nNe`. It reads module `k8fO` and loads module `VE8W` when both conditions hold:

1. `pcType === "oversea"`.
2. `platform.version` is at least `9.7.0`, using three numeric components after
   removing an optional leading `v` (case-insensitive).

Otherwise it loads module `Q2RS`. This selector uses client/platform
configuration, not a prefix or field within `captchaId`. The captured bundle's
`k8fO` configuration has `pcType:"oversea"` and
`platform.version:"V9.7.4"`, so the observed selector chooses **Geelab**.
The separately named package version is `6.1.0`; it is not the field compared
by this selector.

The two SDK modules assign the same global `window.initGeetest4` but use
different defaults:

| Module | Provider | Default API servers | Static servers |
| --- | --- | --- | --- |
| `VE8W` | Geelab | `cap-global.geelabapi.com`, `cap-eu.geelabapi.com`, `cap-na.geelabapi.com` | `static.geelabapi.com` |
| `Q2RS` | Legacy GeeTest | `gcaptcha4.geetest.com`, `gcaptcha4.geevisit.com` | `static.geetest.com`, `static.geevisit.com`, `dn-staticdown.qbox.me` |

Both copy caller options into a config object and build a `/load` request with
`captcha_id` taken directly from `config.captchaId`, plus a generated or supplied
challenge and other display/client settings. Geelab additionally preserves
caller `clientType` and `userInfo`. Neither bounded SDK module detects its
provider from the CAPTCHA ID. API host selection happens by loading the SDK,
with each SDK's own defaults or supplied option overrides. No server query
was made in this follow-up.

For bounded REA verification, exact original module-entry substrings for
`0a1G`, `VE8W`, `Q2RS`, and `1nNe` were copied into inert CommonJS object
wrappers in `analysis/web/captcha-loader-slice/`. They were parsed, never
executed. `slice-manifest.json` binds every substring to original byte offsets
and SHA-256. REA parsed all four files without parse failures; this is an
analyst-created focused slice, not a claim of whole-bundle reconstruction.
REA's conservative semantic relationships retain unknowns, so the branch
interpretation above also cites the exact source span rather than implying a
runtime observation.

- Selector original bytes: `[5212025, 5212422)`.
- Geelab SDK original bytes: `[5197122, 5202805)`.
- Legacy SDK original bytes: `[5206860, 5212024)`.
- REA focused analysis parent:
  `ev_0f72e9627bf1463817e7e291125c79aa9c68b7e2d1f639e250c7bc827c80ce4e`.
- REA summary view:
  `ev_117af5c306f45f8c0d1f2fc45e28d02de48175086ce107cfbec434a49de4ed69`.
- REA module identity page:
  `ev_6e6977178198ceac49e1a88af2c1558f1bb0ab182fa1a55b02540d8bb45e7593`.
- Complete retained records exported to ignored
  `analysis/pcs-captcha-web-selector-evidence.json`.

This changes the compatibility hypothesis: the current official web artifact
uses Geelab for this overseas build, even though the older native loader has
an optional vendor flag. An implementation that always loads the legacy SDK
can therefore use the wrong provider. This is strong static evidence for a
provider mismatch to test, but does not by itself establish that mismatch as
the runtime meaning of `-50106`.

## Modern native CheckGeeTest4 request identity and API version

A further focused REA pass traced the actual modern `LCRequest::postAuto`
implementation in `analysis/installer/bin/LCBaseCommon.dll`, SHA-256
`43c560015034f6193a356f21df06f4111df7a19ba38a91729d6cbbcdd515597e`.
This is the method imported by the modern LCCommon CAPTCHA callback. It
does not use the older generated RestApimd request initializer.

**Modern API version is `3.10.0`.** `LCRequest::setHeader` export thunk
`0x18000202c` reaches body `0x18001a7d0`. At instruction `0x18001af0b`
it loads the literal at `0x1800633b8`, whose defined string is `3.10.0`,
then converts it into the same API-version byte array used for the PCS
signature and outgoing `x-pcs-apiver`. It does not select a per-route
generated numeric version. Thus the earlier `152485` observation in
`captcha-rest-findings.md` applies to the **legacy generated SDK route**,
not to the modern UI callback's `postAuto` path. Version `0` reproduces
neither observed route.

The identity decision is also explicit:

1. `postAuto` at export `0x18000224d` / body `0x180018b60` asks
   `supportPost("login")`.
2. This returns true only when the configured host/UA and stored login
   UUID/credential are nonempty and both login values differ from their
   configured default service key/credential.
3. If true, `post` tags the task `"uuid"`.
4. Otherwise, if `supportPost("default")` is true, `postDef` tags the
   task `"default"`.
5. `setHeader` constructs `uuid\\` plus the stored UUID for the first
   case, or `default\\` plus the stored application service key for the
   second. Its credential comes from the corresponding stored credential.
   There is no `account\\` identity branch.

The pre-login CAPTCHA therefore has a supported default-service request path
which does not depend on the attempted password. A valid existing signed-in
UUID can select the other path; this static observation does not claim the
exact live state of a running Windows process.

The existing `VerificationProtocol.identity` is the same default service
identity configured into this modern client. The EXE call at
`0x1401ec37b` passes helpers `0x1401f3530` (service key) and
`0x1401f3620` (service credential) as arguments 7/8 to
`LCRequest::updateRequestInfo`; the recovered callee stores them at
`+0x60/+0x68`. Bounded original-byte helper inspection reaches the UTF-16
constants at `0x1408e85a0` and `0x1408e85d0`. Offline comparison with
`analysis/verification-service-identity.json` returned **true for both
principal and credential equality**, without printing either value.

- Service key UTF-8 SHA-256:
  `56eb49a2060104862d828ddfb50fb60cdb679c4c3f6428b0000497bbdfd6d060`.
- Service credential UTF-8 SHA-256:
  `4bd1ddf766c2838051d2bc8c36a499fd0ad6f0446a96d91ae30ee4711bec9ecd`.
- These are shipped application protocol constants, not user credentials.
  No account file was read and no real account request was sent in this pass.

Evidence:

| Observation | Evidence ID |
| --- | --- |
| `postAuto` dispatch | `ev_acc4a240d3ca30472387aa60b6fbba3e4f6824cfe0cfe0954034a2a4d1627974` |
| `supportPost` | `ev_ebfeae77f6f420998426a492e95e8583e1f285971de93b6667b4d1528b83727d` |
| `postDef` | `ev_48d4b944fd62d0bcd496c2ddbcd657620326a01aa37534fdd8d26862c362fa3a` |
| `post` | `ev_fc16ed252e30083c3a9bd12170cef8edb34c4936f80afae6aae9ad599eb5c1a7` |
| `updateRequestInfo` | `ev_493720771319ab195927a45160c0fee1171d9567885f9b7eac1ae19e31adddf4` |
| `setHeader` | `ev_841e273ae7fe07062ed80d96a5545614f6c6fed9f0d1869baf58db779a1a7c70` |
| Actual `setHeader` instructions | `ev_bf85c97a1bda19d22f00928bcd825852222b6f99d7dee153833d93b24ce24f4d` |
| API-version defined strings | `ev_261194e04137bb446d9868319cc1d715b27667c0251342a9d6105b152cc78deb` |
| JSON envelope / transport | `ev_e75ca401fec55b19977beaffce01404fae12b4e6179aaea3f4d1e061ec526b81` |

The complete native records are exported to ignored
`analysis/pcs-captcha-modern-postauto-evidence.json`. The native session
was closed. Original-byte EXE helper excerpts are saved in
`analysis/installer/captcha-default-service-{helpers,constants}.asm`;
the existing full update caller is
`analysis/installer/native-tls-ca-consumer-two.asm`.

The bounded official main web bundle contains no literal
`CheckGeeTest4`, `captchaOutput`, or `captchaMetaData`. Its standalone
v4 page reports challenge results to the native bridge, consistent with the
actual LCCommon caller. This negative source search is limited to the captured
main bundle and standalone page, not every remotely loadable chunk.

The modern reconstruction should submit CheckGeeTest4 with the existing default
service identity and `3.10.0` for both Login and GrantingCredit CAPTCHA
purposes, retaining the pending account identity for the subsequent GetToken
retry. API versions of distinct GetValidCode/GrantingCredit endpoints are
separate schema questions. The server meaning of code `11010` has not been
established by this static inspection; a live request with the corrected native
request behavior is the concrete next validation.


