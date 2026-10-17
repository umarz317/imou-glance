# Consumer PCS configuration and camera-list evidence

Static reverse engineering of the supplied Windows client, 2026-10-16–17. This
does not establish that requests were accepted by Imou or that a camera played.

The analyzed `LCBaseLogic.dll` has SHA-256
`2c75495f9a8898338105f484f1deb922d8fa694c7a831f20377282b16f638b24`.
Raw REA records are in ignored `analysis/pcs-*-evidence.json`; readable temporary
pseudocode/disassembly is in ignored `analysis/installer/pcs-*`.

## Client identity

`LCLogicFunctions::GetOverSeaAppId`, implementation `0x1802e7bd0`, decodes
`ZWFzeTRpcGJhc2VwYw==` to **`easy4ipbasepc`**. `SetPostClientInfo`, implementation
`0x180242f30`, selects that value for non-native builds, `lcbasepc` for native
builds, with a separate OEM override. The ordinary project value is `Base`.

Evidence:

- `ev_da5d75e05702e5b3619f1eef88c7b33fa258d08e97b999577dd029b88fef8bef`
  (`pcs-appid-evidence.json`).
- `ev_0c481ab7a8ff5225897191f9f1c9b41638d0600919f9f0a3773b45c652f93cf0`
  (`pcs-clientinfo-evidence.json`).

The latter builds a UUID principal and supplies the principal, UserInfo token,
encryption mode and app ID in `LCSDK_RestApiParameter_t` to
`LCSDK_Api::initRestApi`. It also calls `hsview_client_set_client`,
`hsview_client_set_client_version`, `hsview_client_set_project`,
`hsview_client_set_client_OSBits`, `hsview_client_set_client_ua_info`, and
`hsview_client_set_client_ua_ext_info`.

`SetConfigClientUA` simply stores the supplied string at instance offset
`0x3e0` and forwards it to `LCSDK_Api::setConfig(0, value)`; it does not create
the UA. Evidence `ev_eaf4b3ca927d0f9a843db6230d39b66065e11d11ad994998abcb9644694e8152`.

Additional source-byte/LLVM disassembly observations from `Imou_en.exe`
function `0x1401eb350` (not a REA decompilation of that EXE):

| Field | Observed source |
| --- | --- |
| `clientType` | Literal `pc`, supplied at instruction `0x1401eb4a0` |
| `clientOS` | Helper `0x1405b6e20` constructs literal `Windows` from VA `0x1409a1ee0` |
| `clientVersion` | App configuration offset `0x230`; leading `V` stripped if present |
| `clientOV` | OS-version helper `0x1405b6e70`, which queries Windows registry |
| `terminalModel` | Same OS-version string used for `clientOV` |
| `terminalId` | Helper `0x1405b71e0`; not a fixed shared identifier |
| `clientProtocolVersion` | Literal `V9.7.0` in both native and overseas branches |
| `project` | Literal `Base` outside OEM override |
| `language` | `en` overseas default; native branch uses `zh_CN` |
| `encryptType` | App configuration offset `0xb4`; `Function/EncryptType` setting defaults to 2 (MD5 and SHA-256) |

These are Windows observations, not instructions to mislabel the new macOS
application. The service's allowed values and minimum accepted fields have not
been validated at runtime. No fixed client version, terminal ID, or OS version
is inferred from an unrelated string.

## Authentication helpers

`FUN_1802df6e0` returns true exactly when the input is non-null and
`strncmp(input, "account\\", 8) == 0`.
Evidence `ev_78f26fa386270e10d7a42eb6fb1d1ec813bb82a3f2ec77c04b531e1bbe3ac121`.

`FUN_180300ad0` initializes `EVP_md5`, hashes the supplied bytes, and formats
the 16 digest bytes using `%02x`. Its result is 32 lowercase hexadecimal
characters. Evidence
`ev_f7008b6ed71ba77343479fdef91d2d3ebe36e3a36470a4750ffc8efec8d3dd4d`.

`LCLogicImpl` constructor sets instance offset `0x314` to zero. However,
`LCLogicImpl::Init` overwrites that field from `LogicParam_t + 0x2c`, so the
constructor alone does not establish the effective configured encryption mode.
Evidence:

- `ev_f92cbe6454ee00395b258821b300396e9906848a78b2a310774af4db5930295a`
- `ev_9dc5979cef2ea8e8c756d675115f77c12f00aedbfc2a4a2ce906c852c1564afc`

## Basic camera pagination

`OrganizationLoader::GetPageDeviceBasicList`, implementation `0x180121550`,
sends `/pcs/v1/device.list.BasicPageGet` using client handle type 1:

```json
{"data":{"bindId":-1,"limit":50,"familyId":"-1"}}
```

`bindId` is a JSON integer constructed from a signed 64-bit argument;
`familyId` is the string `"-1"`. It expects `data.deviceList` to be an array.
Each item supplies:

- `bindId`: signed 64-bit integer.
- `productId`, `deviceId`: strings.
- `channelList`: array of objects, each with `channelId` as a string.

`LoadDeviceBasic` starts the cursor at `-1`, advances to the last returned
binding ID, and continues until an empty page. It retries a failed page up to
three attempts overall in its loop. It merges repeated product/device identities
and deduplicates their channel IDs.

Evidence:

- `ev_897cc5525b91016bc371b172a69250b783a91c97be98659cc6704e35dcca411a`
  (`pcs-GetPageDeviceBasicList-evidence.json`).
- `ev_255c461dc80ab320e6ea0d168b2240316ff5a8f8e6a1a2784715a752e24e4824`
  (`pcs-devicelist-evidence.json`).

## Camera details

`OrganizationLoader::GetPageDeviceDetailList`, implementation `0x180122bb0`,
sends `/pcs/v1/device.list.CommonInfoGetByIds`:

```json
{"data":{"deviceList":[{"productId":"…","deviceId":"…","channelList":["0"]}],"needNewSecret":true}}
```

The detail request's `channelList` contains **strings**, whereas BasicPageGet's
response uses objects containing `channelId`. The response is
`data.deviceList[]`, with each item passed to `parseOneDevice`.
Evidence `ev_a5b21849edc048257f2207babcd2f82529a13012074bc8dc0c2ca663e0a8798c`
(`pcs-GetPageDeviceDetailList-evidence.json`).

`parseDeviceInfo` reads `productId`, `deviceId`, `name`, `deviceModel`,
`streamEntryAddr`, `streamEntryAddrV3`, `streamEntryAddrV4`, `salt`, `encryptMode`,
`deviceUsername` and `devicePassword`. It uses `status` as a string, except
some product/device properties override state for low-power devices.

Its `mediaConfig` handling calls `asString` and then parses that string as JSON.
The embedded object may contain `wssekey`, `wssekeyNew`, `deviceAccount`,
`deviceAccountNew`, `devicePassword`, `streamUrl`, `streamProtocol`,
`streamEncryModel` and resolution choices. This branch is associated with the
`NVR_S` path in this function; other device paths must be checked separately.

Evidence `ev_785bbea089787b2a64e3d7689ee08241c2309d3074bbb8a7864240cc7ba4f316`
(`pcs-parseDeviceInfo-evidence.json`).

### Ordinary IPC channel metadata

`parseOneDevice` at `0x18012add0` parses device-level information, then iterates
the ordinary device's `channelList[]` and calls `parseChannelInfo` at
`0x180127f20` for each channel. That parser reads `channelName`, `channelId`,
`status`, `picUrl` and **channel-level** `mediaConfig`. It parses mediaConfig
as a JSON-encoded string. Merging each channel object over its device object
therefore exposes ordinary IPC mediaConfig correctly.

There is a material difference from NVR metadata: `parseChannelInfo` reads
`mediaConfig.streamProtocol` with `asInt`, as a **scalar integer**. The
device-level NVR_S parser reads a protocol array. A client must support both
scalar `1` and arrays containing `1`; an array-only parser rejects ordinary
IPC cameras. Channel labels use `channelName`, not `name`.

Evidence:

- `ev_49f3df7a0f2d1e1f350659f40ac8cdf61473ce55994666de14ad210b7219e9b0`
  (`pcs-parseOneDevice-evidence.json`).
- `ev_0f7e353fae330e9c52f1f940804e9a8152b5c601ed79741d460889eaa1cb5da3`
  (`pcs-parseChannelInfo-evidence.json`).

The top-level `devicePassword` is stored as a wire value and then passed through
`DevicePasswordCrypto::ApplyListDevicePassword`. It must not be used directly
as a camera safety code. The new media secrets are processed by
`ResolveMediaWsseKey` and `ResolveMediaDeviceAccount` with the device ID; old
values are fallback inputs.

## Device-secret decoding

`DevicePasswordCrypto::ResolveEncType` returns 2 when the product ID is
nonempty and the device's `encryptMode` is 5, and returns 0 otherwise.
`ApplyListDevicePassword` deliberately skips list-wire decryption for that
type-2/GCM case and tries a cached database password instead. A new client has
no such cached password and must not mistake the list value for clear
credentials. The later recovered `DevicePasswordGet` flow below supplies a
fresh encrypted password automatically; a missing local cache alone does not
justify requiring the user to enter a camera safety code.

For other devices the exact legacy operation is:

```text
keyText = lowercaseHex(MD5(uppercaseASCII(deviceId) + "DAHUAKEY"))
key = UTF8(keyText)             # 32 bytes: the hex text, not the 16 digest bytes
iv = UTF8("0a52uuEvqlOLc5TO")   # 16 bytes
ciphertext = Base64Decode(wireDevicePassword)
clear = AES-256-CBC-PKCS7-Decrypt(key, iv, ciphertext)
```

The helper `GetDKeyString` decodes `REFIVUFLRVk=` to `DAHUAKEY`.
`AesDecryptDeviceUserInfo` transforms the ID to uppercase, concatenates the
ID on the left and DKeyString on the right, and calls the previously verified
lowercase-hex MD5 helper. `FUN_180300560` decodes Base64 and calls
`EVP_aes_256_cbc`, `EVP_DecryptInit`, `EVP_DecryptUpdate`, `EVP_DecryptFinal`.
The shipped code does not check every OpenSSL return value; a reconstruction
should reject malformed Base64, bad block lengths and invalid padding instead
of reproducing unsafe error handling. None of these legacy steps use
`wssekey` as the decryption key for top-level `devicePassword`.

Evidence:

- `ev_ae87b76986f5fda3f70527d880f78322f56831d8f3701902661bdcf23fad19cd`
  (`pcs-ResolveEncType-evidence.json`).
- `ev_80ebd056c13ca95868a3a4a664b5d5ef33d6409a2245c3b6258ea1af697addca`
  (`pcs-ApplyListDevicePassword-evidence.json`).
- `ev_edb1f7645aa8051bd2d792b2ca989d49f275d2326cd5fef08079a010b9d167a0`
  (`pcs-AesDecryptDeviceUserInfo-evidence.json`).
- `ev_703de77eefcd494ef2cc3de8815ef6306c1ddc3597fab0fe8dbef03da10777ae`
  (`pcs-GetDKeyString-evidence.json`).
- `ev_16b41fd1a4faee4efe1a93ff0e5cfd06fd615c90e2f8501088cdeeb5ad77a29f`
  (`pcs-LegacyAES-evidence.json`).

`DecryptWirePassword` can decrypt a separate type-2 response using a supplied
salt and context string `device_pwd`, through `FUN_180314740`. That is a
separate path from `ApplyListDevicePassword`, which deliberately skips GCM
list values. `DecryptDeviceListSecretNew` calls the same lower-level GCM
helper with device ID, a null salt field, and an empty context field.
The lower-level GCM derivation was subsequently recovered below; it differs
from the legacy CBC formula.

`ResolveMediaWsseKey` first decrypts the old `wssekey` with the legacy helper,
then prefers a successfully decrypted `wssekeyNew`, falling back to that old
decrypted value. `ResolveMediaDeviceAccount` prefers a successfully decrypted
`deviceAccountNew`, falling back to the old `deviceAccount` value directly.
Thus old `deviceAccount` is not processed through the same legacy AES path
as old `wssekey` in these resolver functions.

Evidence:

- `ev_0fea855f97726aa058bf09c672582e67aecf73beb62cea3b594db85af40a409d`
  (`pcs-DecryptWirePassword-evidence.json`).
- `ev_7e6aa146f0250f3906d7080cf8912670e236e301aea56a4ae2abe3bd8fe3fe3d`
  (`pcs-DecryptDeviceListSecretNew-evidence.json`).
- `ev_f88710e4ea572ebfa0a43ef6cec630799bfcb4027abe4f8da6b79a06f79dd85c`
  (`pcs-ResolveMediaWsseKey-evidence.json`).
- `ev_64573c433340c2db11e06618858459daf1d3e897b1d9965d981b66170202acb5`
  (`pcs-ResolveMediaDeviceAccount-evidence.json`).

### Automatic device-password retrieval

`DeviceManager::GetDevicePasswordSync` (`0x18007b270`) uses the signed-in
type-1 client, without resetting its authentication, to POST
`/pcs/v1/iot.control.DevicePasswordGet`. For an ordinary IPC its body is:

```json
{"data":{"deviceId":"<serial>","productId":"<productId>","channelId":"0","salt":"<fresh16characters>"}}
```

The channel ID is a string and is omitted when the native channel argument is
negative. `AppendDevicePasswordSaltRequest` (`0x1800b1410`) generates and
adds salt for this request. `GenerateSaltForEncType2` (`0x1802d6c80`) produces
16 characters from `ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789`.
The response reads `data.devicePassword` as a string and `data.encType` as an
integer, defaulting to zero when absent. `ParseWireResponseEncType`
(`0x1802d6c50`) keeps exactly 2 as GCM and maps every other value to legacy0.
The same locally retained request salt is used to decrypt; no response-salt
field is read. NVR-specific branches add a `targetDevice` object and are
outside the ordinary IPC request above.

`HandleDevicePasswordWireResponse` (`0x1800b1a40`) passes the encrypted password,
the request device ID, request salt, and response encryption type through
`DecryptWirePassword`, rejects empty output, and then calls
`CacheDevicePasswordPlaintext` (`0x1800b1600`). Cache persistence is downstream
of decryption; an existing Windows/iPad database is not a prerequisite for
recovering the response plaintext.

The type-2 device_pwd AES-GCM key is exactly:

```text
marker = Base64(SHA256(UTF8("Security-ISRC")))[0..<16]
       = "gMwe9k+GV0UlpBQd"
key = SHA256(UTF8(requestSalt + marker + requestDeviceId))
clear = AES-256-GCM-Open(key, Base64Decode(devicePassword))
```

The decoded wire format is nonce12 || ciphertext || tag16, with no associated
data. The outer digest is raw SHA-256 bytes, not hex text. The marker's digest
is SHA-256 and its encoding is Base64, not MD5 or hex. Native helper
`0x1803153d0` calls marker helper `0x18031d0a0` through thunk `0x180005597`.
That helper calls the import `EVP_sha256` and Base64 converter `0x18031d130`,
then the caller copies its first16 ASCII bytes. The two concatenation overloads
are `(salt + marker) + deviceId`. `0x180314740` computes the outer digest,
extracts nonce and tag, and verifies the tag using EVP_DecryptFinal_ex.

`DeviceSecret.decodeResponse(deviceId:wire:encType:salt:)` implements this
recovered flow with CryptoKit authenticated decryption. It preserves the
legacy decoder API, rejects malformed/truncated Base64, authentication failure,
empty plaintext, invalid UTF-8 and control characters. Synthetic independent
Node.js crypto fixtures cover the recovered formula and failures; no real
camera secrets were logged or used in fixtures.

Validation: `swift test --filter DeviceSecretTests` passed all three focused
tests on 2026-10-17. The first sandboxed attempt could not write the compiler
cache; the local test was rerun with the required compiler-cache access. This
worker performed no live DevicePasswordGet or camera playback request.

Canonical REA evidence:

| Function | Evidence ID |
| --- | --- |
| GetDevicePasswordSync | `ev_4b3dec1491f5aebdeebcad39f196ee74aa5348482bdf3b302a6afd0cfd523f16` |
| AppendDevicePasswordSaltRequest | `ev_959a7c40773e6b6ab8473e370343703d14fb9230ef4447afad65c1e4d7998a38` |
| GenerateSaltForEncType2 | `ev_e262057f8eaeedbcafbbb007e33e8d43d6d17e41e70cc5555d4017265841da8c` |
| ParseWireResponseEncType | `ev_ffc0e4ef520863c59d47f5f68d78370bc91ac37beffff48c701a8a6b7e2d51bf` |
| HandleDevicePasswordWireResponse | `ev_1a43103ca41ac9d5e41b3382662447451ea915aeab95a0efe5175c78f245113c` |
| CacheDevicePasswordPlaintext | `ev_1e250d31c1ce4e30bed18318cc3efc7894b59b469bfd714d2455c34b283606b2` |
| Device key material | `ev_03afff0bd952e98112f35e1ced034547b8bc0a604ab4f29bb2babf6bf582e097` |
| SHA-256-to-Base64 marker | `ev_bad4abe559d8bb8daf1dc02094bf871c85455972b03eb5e16a587a19266bc4de` |
| Base64 converter | `ev_7f51a9de22b33f0b6289b6b23c22d5cd01df4f6116516d4f62c5d34ebe41acf2` |
| AES-GCM decryptor | `ev_67206d603054e2fe4b6406057dafc335f596ea4c6dd98077611e6d0ac5f82fb3` |

## Login host selection boundary

The existing LoginWithConfig pseudocode calls `GetLoginPhaseClientHandle`,
not unconditionally handle 1. Original-byte disassembly of that helper at
`0x180245780` shows it checks `UserManager + 0x8a0`; when enabled, it chooses
handle 5 if present and logs an `entryUrlV2` fallback when absent. Otherwise
it uses handle 1. LoginWithConfig clears that flag just after sending Login.

BasicPageGet and CommonInfoGetByIds use handle 1. `GetClientHandle(1,false)`
itself returns the override handle at instance offset `0x348` when nonzero,
otherwise the ordinary type-1 slot. The exact endpoint-to-handle creation
mapping is not established by these functions. It would be incorrect to infer
that every PCS path must use V2, or that V2 Login is unsupported.

### PCS success and account failure handling

The subsequently recovered `DealResultRet` implementation **explicitly maps
PCS code `10000` to native status zero**. Its alternate, non-PCS branch uses
code 1000. The API's 10000 must therefore be accepted before inspecting the
GetToken `data` object; it is not itself an account failure code.

For PCS responses the relevant exact mappings are:

| PCS code | Native status |
| --- | --- |
| 10000 | 0 |
| 10002 | 2 |
| 10005 | 4 |
| 10006 | 5 |
| 10007 | 4 |
| 10009 | 6 |
| 11001 | 1, through the unmapped-code default |
| 12112 | 29, terminal binding verification required |
| 12114 | 35, GeeTest CAPTCHA challenge |

The function does **not** attach a semantic label to JSON code 11001. It is
not evidence to label that response as an invalid password, signature failure,
missing parameter, or terminal trust challenge. The integer 11001 also occurs
in RestApimd's linked Windows networking code as `WSAHOST_NOT_FOUND`; that is
an unrelated error namespace and must not be applied to an HTTP JSON result.

Evidence `ev_8a95c8ceac630ff187576907a4ac1a6aab1a43ef2fa91a3a528a76dee2dbf2c6`
(`pcs-DealResultRet-evidence.json`). Source-byte cross-check:
`0x1802deb4a` compares response offset `0x28` to 10000; the 10000 switch branch
at `0x1802deef1` leads to the zero return. Other unknown values take native 1.

After the native-zero GetToken envelope, the existing GetToken implementation
checks `data.failNum`. If present, the string `"5"` becomes native status 6;
other values become native status 3. A 10000 envelope can therefore contain
a credential failure rather than a token. Check the data fields before
requiring token/username/session values.

`GetTokenByServer` passes login-event fields at offsets `0x50` and `0x70`
directly to GetToken; it does not hash them in this wrapper. Its ordinary
password path then obtains regional entry URLs and stores token/user values.
`OnRequestLogin` calls that wrapper, configures regional clients, sets UUID
and token authentication, and calls LoginWithConfig. No
`GetTwoStepVerifyState` call was found in these recovered orchestration
functions or in the bounded LCBaseLogic string/import search.

The `PcTerminalLoginHint` helper at `0x1802458d0` reads GetToken response fields
`hasOtherPcTerminalLogin` and `pcTerminalManagerSwitch`. The wrapper copies
the 12-byte hint to the event at offset `0x51c`. This is response metadata;
it does not establish a required trust request preceding GetToken.

Evidence:

- `ev_771cc179a8d39a92c1fdb87a0093989940d3ed2719435597d20e21ed1137b690`
  (`pcs-GetTokenByServer-evidence.json`).
- `ev_f395d75606e2a276d29ccc2463fbd7b33c445f3a6cb21421a4902dfc719c7b45`
  (`pcs-OnRequestLogin-evidence.json`).
- `ev_2f34b05bcad6b4de5073baf003bdc79d1b11523c02e95193db2e52feea472416`
  (existing `gettoken-pseudocode.c`).

This follow-up used no real-account calls and did not retry submitted user
credentials. It does not establish the server's undisclosed meaning of 11001.

## Consumer login CAPTCHA

The account-authentication SHA-256 prehash is lowercase hex. Original-byte
disassembly of `LCSHA256Hex` (`0x180314e50`) calls the thunk at `0x180007e3c`,
which jumps to the byte-to-hex routine at `0x180317cb0`. That routine indexes
the literal `0123456789abcdef` at VA `0x1803a6b38` (file offset `0x3a5d38`)
for both nibbles. `LCSHA256Hex` then copies the result without a case
transformation. This agrees with lowercase account prehashing; uppercase
would differ from the shipped client. Bounded original-byte record:
`installer/pcs-sha256-case.asm`.

The EXE also establishes the encryption-mode fallback. At `0x14053e2ed` it
loads setting key `EncryptType`; at `0x14053e303` it loads section `Function`;
at `0x14053e319` it passes integer 2 as the default to settings helper
`0x140535120`. The helper constructs a QVariant from that integer, reads
`QSettings::value(key, default)`, converts the result with QVariant::toInt,
and the caller stores it to config offset `0xb4` at `0x14053e348`. A bounded
text search of the shipped `SystemConfig.ini`, `Native.ini` and `Settings.ini`
found no `EncryptType` override. The shipped fallback is mode 2, both digest
branches. Bounded original-byte record: `installer/pcs-encrypt-type-default.asm`.

PCS code 12114 (`0x2f52`) maps to native status 35 (`0x23`). The original
EXE instructions in `LoginDlg::HandlePasswordLoginFailed` (`0x14021b550`)
dispatch that status to `0x14021b97e`, which constructs `LCGeeTest`, connects
its `signalSuccess`, and invokes `showGeeTest`. Status 31 uses a separate
terminal-trust dialog. Thus 12114 is a CAPTCHA challenge, not evidence of a
concurrent PC login or a missing trusted terminal. The annotated original-byte
record is `installer/pcs-login-failure-annotated.asm`.

`LCGeeTest::showGeeTest` (`0x1800053f0`) reads the failed GetToken response's
`data.captchaData.captchaId`, optional `data.captchaData.verifyToken`, and
`data.captchaMetaData`. Its full overload (`0x180005b40`) captures those values
along with the account and usage. The EXE supplies usage `"Login"`.

The official remote page is
`https://pc.imoulife.com/h5-pc-base-v6/static/GeeTest.html?data=` followed by
the JSON settings. This comes from the EXE's page-index helper (`0x1405ca050`,
case 15 at `0x1405cad0e`) and H5-base helper (`0x1405cae50`). The URL replaces
`index.html#/` with `static/GeeTest.html?data=`. `loadGeeTest` (`0x180008770`)
passes only `captchaId`, `protocol:"https://"`, `language:"en"`, and
`nextWidth:"340px"` in this JSON; the overseas caller does not enable the
optional `captchaVendor:"geelab"` setting. Account, password, metadata and
verifyToken are not page URL parameters in this implementation.

The web bridge method is `notifyGeeTestState`. It receives a JSON string with
`type` (`ready`, `result`, `close`, `fail`, or `error`). On `ready`, the native
app invokes `window.captchaObj.showCaptcha()`. A human-completed `result`
contains `data.captcha_id`, `captcha_output`, `lot_number`, `pass_token`, and
`gen_time`. The native handler (`0x180008d00`) reads all five string fields;
close/failure/error states do not emit success.

The result callback (`0x180006de0`) posts through `LCRequest::postAuto` to
`/pcs/v1/common.validcode.CheckGeeTest4`, with a 10,000 ms timeout. Its object
contains string fields `account`, `usage`, `captchaId`, `captchaMetaData`,
`captchaOutput`, `lotNumber`, `passToken`, and `genTime`, plus optional
`verifyToken` when supplied by the challenge. For a nonempty account it sets
boolean `isEncrypt:true` and encrypts the UTF-8 account as described below.
The callback after that request (`0x1800078d0`) checks request status
`"success"`, closes the dialog, and emits `LCGeeTest::signalSuccess()`. It
does not read the response token or install a CAPTCHA header. The generic
request host/signature/version routing is outside these callback functions.

### CAPTCHA account encryption

The exact default-context key is the raw 32-byte digest:

```text
SHA256(UTF8("F9TtRyv7X89nM0vp2EKOjdKLFnjlrN9rENCRYPTKEY"))
```

`0x180006de0` supplies the static secret, null salt, and a nonnull empty
context string. `FUN_180018830` appends `ENCRYPTKEY` to that secret for this
context. The append direction is established by `FUN_1800191f0` ->
`FUN_18001ae20` -> `FUN_18001ae50`; the final helper copies the suffix to
`destination.data + destination.size`. `FUN_180019830` is an identity return.
The empty context is valid; `FUN_180017780` checks its pointer, not its length.

`FUN_180017780` hashes this material using `EVP_sha256`, encrypts using
AES-256-GCM with a random 12-byte nonce, supplies no associated data, and
obtains a 16-byte authentication tag. The wire value is standard Base64 of
`nonce || ciphertext || tag`, without a prefix or line breaks. The Base64
helper (`0x180020460`) uses `BIO_f_base64` with `BIO_FLAGS_BASE64_NO_NL`.
CryptoKit's AES.GCM combined representation has this same framing.

Bounded REA evidence for this flow:

| Function | Evidence ID |
| --- | --- |
| Raw-response showGeeTest | `ev_f9b8423ba8e33b1f2fe7b8d051f8de3ad2ad4469ec7b4b3e73c8c164ad159c74` |
| Full showGeeTest | `ev_9c1a198d2943f4ee1f37efdc28874e09759e4c147571a5fb69e9238f69f307ee` |
| loadGeeTest | `ev_1d11e7d8a1716d5d8937aa8199e8ca188bea446474343650c228c8fc63353d98` |
| onNotifyGeeTestState | `ev_c3dac2dde7da18d5e16dd40e175f79b5f0af1a1ebe27386ee3af2e90bba3ff9c` |
| Result request | `ev_cbe1b357364454b9a6a2bbff395c5323ab6783c42825c7fd97cd8b1740353259` |
| Checked callback | `ev_b0109b954cdbec06bd471f701153fc4ccf572a6c5431e5d98df378a58e3ac8fc` |
| AES-GCM helper | `ev_dff38014964a634ad94d03a2c90d1ac0098625216266354c660752955599434c` |
| Key material | `ev_6c5d7ed5da45cf92094cf73e1dedfa4560669a6895fc454491e911e1a93e59a5` |
| String append | `ev_b2e2474ca5b35334569430ecdbc1151d53ff09dda979562b679ed070796302a5` |
| Base64 encoder | `ev_9bd255d62897047c082e47601986e2e1d62e05858c96085fed4e9f9b7eae64cc` |

These findings use only static shipped-artifact analysis. This worker did not
perform a live account request or solve a CAPTCHA.

## Terminal binding verification (12112)

PCS code 12112 (`0x2f50`) maps to native status 29 (`0x1d`). The password
failure handler's byte jump table at `0x14021c908` maps native29 (index26) to
slot5 in the target table at `0x14021c8e4`, leading to `0x14021bf73`.
This is a terminal-verification flow. The image-CAPTCHA branch is separately
located at `0x14021b6a1`; the GeeTest branch is `0x14021b97e`.

For an ordinary overseas account, the handler resolves the login edit's
`realUserName` property when present (otherwise its entered text), then at
`0x14021c108` explicitly checks native29. At `0x14021c15c` it calls the
BindPhoneWidget helper `0x1401f7450` with that account, an empty additional
string, and flags `(true,true)`. A nonempty account enters its terminal
verification UI at `0x1401f78f4`.

The fifth flag is saved at widget offset `0x78` and controls the explanatory
label at `0x1401f7ac1`. Native29 passes true, selecting
`pc_terminal_bind_verify_attention` at `0x1401f7ada`. The shipped English
translation in `ImsTranslates/ims_en.qm` explains that the account has activated
terminal binding and must receive a verification code for terminal
verification. False selects `pc_terminal_bind_verify_untrust` at
`0x1401f7c3f`, a related message about authorizing an untrusted device. These
are distinct labels even though both use the same account-code form.

The title is `pc_terminal_bind_verify` (English: `Terminal binding Verify`).
The label `pc_terminal_bind_verify_send` identifies the registered account as
the destination for the code. The form includes a send-code button, code
entry, and confirmation. The code edit is given maxLength6 at `0x1401f8200`;
the helper configures its send/submit signal connections rather than issuing
a GetToken retry itself. The send/verification API schemas are a separate
worker's bounded task; this UI trace alone must not be used to invent request
fields or silently bypass terminal binding.

### Exact terminal send and submit constants

The existing-account terminal UI calls send helper `0x1401f8d50` with its
account and a false third argument (`0x1401f6243` and `0x1401f71bd`). That
argument changes its default usage from `BindAccount` to `GrantingCredit`
at `0x1401f8dbc`. For overseas email accounts the helper changes default
type `phone` to `email` after the email-regex match at `0x1401f8eed`. The
areaCode is empty for email. Its final UserManager::GetValidCode virtual call
at `0x1401f90ae` passes account, type, areaCode, usage, resetAuth, accessToken.
The resetAuth boolean is explicitly **true**: instruction `0x1401f9074` is
`c6 44 24 28 01`, storing 1 into the stack argument immediately after the
four strings. Stack `0x20` contains usage; `0x30` contains the optional
accessToken. The service-auth reset is therefore enabled for this flow.

Submit helper `0x1401f92e0` checks the terminal-binding flag at widget `+0x78`
at `0x1401f9407`. Its true branch sends UserManager::GrantingCredit at
`0x1401f9560`, passing validCode, type (`email`), account, and areaCode (empty).
It does not add usage. The virtual method identity is independently checked
against the LCBaseLogic PE: its GetValidCode thunk `0x180006c4e` appears at
vtable address `0x18038f108` (slot `+0x68`), and GrantingCredit thunk
`0x1800055d8` appears at `0x18038f120` (slot `+0x80`).

The GrantingCredit result branch at `0x1401f5625` tests event result `+0x14`
for zero at `0x1401f5667`. Success reaches the queued invocation of
`SignalGrantingCreditSuccess` at `0x1401f5bff`/`0x1401f5c0b`; failure displays
verification-code/credit-error feedback. LoginDlg's Qt metadata (table at
`0x1408ad0c0`) maps `OnGrantingCreditSuccess` to method46. Its static metacall
case (`0x14011161c`) calls `0x14020f540`, which hides verification UI, clears
loading, then calls the normal password-login handler `0x140209900`. That
handler uses the account/password edits and performs the ordinary login
virtual call at `0x140209ff7`. Successful authorization thus retries normal
password login; this recovered path adds no extra ticket header or body field.

Additional original-byte records: `installer/pcs-terminal-send.asm`,
`installer/pcs-terminal-submit.asm`, `installer/pcs-terminal-success.asm`, and
`installer/pcs-terminal-login-retry.asm`.

Original-byte evidence is preserved in
`installer/pcs-login-failure-annotated.asm` and
`installer/pcs-terminal-verify-ui.asm`. No live account request was made in
recovering this flow.

## Limits and tool lifecycle

Only the supplied shipped binaries and existing reports were read. No real
account credentials or live tokens were used. The first one-shot CLI search
completed analysis but reported `cleanup_incomplete` because the process
ownership check returned macOS `sysctl_errno_22`; a subsequent `ps` check
confirmed its reported process had already exited. Its completed search
record is retained in `details.partial_observation`.

The later batches used private REA BinarySession instances with the configured
Ghidra 12.1.4 provider and created canonical evidence through REA's own
`createEvidence`. The first, second and fourth batches closed successfully.
The third batch had the same ownership-check error; its reported PID 26624
was subsequently confirmed absent with `ps`. The later error/orchestration
batch also reported cleanup incomplete (`kill EPERM`), and its PID 30119 was
subsequently confirmed absent with `ps`. They did not change the parent's
shared MCP target or modify shipped binary bytes.
