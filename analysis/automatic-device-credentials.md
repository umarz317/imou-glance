# Automatic camera credentials — static Windows evidence

The shipped Windows client retrieves the camera password automatically using the signed-in consumer session. A missing locally decoded password is not evidence that a user must type a safety code.

Artifacts: `LCBaseLogic.dll` SHA256 `2c75495f9a8898338105f484f1deb922d8fa694c7a831f20377282b16f638b24`; `RestApimd.dll` SHA256 `7aff27e0199c3182f1d630e7d95bc0084b787918f9014d4a968d7d27e185981f`. Addresses below are image virtual addresses; image base is `0x180000000`.

## Retrieval request and response

`DeviceManager::GetDevicePasswordSync`, VA `0x18007b270`, uses `/pcs/v1/iot.control.DevicePasswordGet`. Native UI worker's complete decompilation is `installer/pcs-GetDevicePasswordSync.c`, evidence `ev_4b3dec1491f5aebdeebcad39f196ee74aa5348482bdf3b302a6afd0cfd523f16` in `pcs-GetDevicePasswordSync-evidence.json`. Independent instruction dump: `device-password-sync-annotated.asm`.

For an ordinary standalone camera, it sends POST JSON:

```json
{"data":{"deviceId":"<camera serial>","productId":"<product ID>","channelId":"0","salt":"<fresh 16 alphanumeric ASCII characters>"}}
```

`channelId` is a decimal string and omitted only when the caller's channel number is negative. Special NVR cases add `targetDevice` with `chn` integer, `pid` product ID, `sn` serial; these should not be guessed for ordinary cameras. `AppendDevicePasswordSaltRequest` adds fresh salt before serializing the final `data` object. Native worker owns detailed salt/crypto mapping.

Successful response parsing reads `data.devicePassword` string, plus optional integer `data.encType` (default zero). `encType` is the wire encryption type, not the live video encryption mode. The response is passed to `HandleDevicePasswordWireResponse` with the **request's salt**. Do not use the unrelated `things.control.GetSecretKeyDetail` endpoint, whose request and response concern lock keys.

## Authentication and API version, independently checked

* `GetDevicePasswordSync` at `0x18007bbcb`–`0x18007bbdf` obtains `GetClientHandle(1,false)`; then `0x18007bbe4`–`0x18007bc17` invokes `SendRequestWithUri(handle,result,uri,body,10,true,false)`. It does not install a service identity or reset account authentication.
* `GetClientHandle` actual VA `0x1802f1480`: for type 1 and `false`, returns cached handle 5 if available (`0x1802f1507`–`0x1802f155b`), otherwise regular handle 1 (`0x1802f155f`–`0x1802f1586`). Dump: `device-password-get-client-annotated.asm`.
* `SetAuthUuidAndTokenConfig` actual VA `0x180242330` constructs `"uuid\\" + UserInfo.uuid` (UserInfo offset `+0x20`) at `0x18024235f`–`0x1802423aa`, takes the returned account token at UserInfo `+0x40`, and sets the same `GetClientHandle(1,false)` through `SetRestClientAuthEx` at `0x1802424f8`. It also explicitly sets cached handle 5 to the same UUID/token at `0x1802425fa`. Dump: `device-password-auth-uuid-annotated.asm`.
* `SendRequestWithUri` actual VA `0x1802ddda0` forwards to import `hsview_client_request_with_uri` at `0x1802ddfd3`, through import stub `0x1803125c4` / IAT `0x180569bb0`. Dumps: `device-password-send-uri-annotated.asm`, `device-password-uri-import-annotated.asm`.
* RestApimd `hsview_client_request_with_uri` VA `0x1800095d0` builds POST/application/json and explicitly loads string **`"0"`** at `0x180009646`, assigning it to request field `+0x38` at `0x18000965e` (request stack base `+0x40`, destination `+0x78`). It selects SaaS URI builder and signer at `0x1800096b7`–`0x1800096c6`. Dump: `device-password-rest-uri-annotated.asm`.
* Existing signer decompilation `direct-sign.c` reads request `+0x38` into its canonical `x-pcs-apiver` field (lines 580–594 / 636–650) and outgoing header (lines 710–711). Therefore this endpoint uses **API version 0**, unlike generated GrantingCredit's version 185612.

Minimal request implementation: current account UUID/token identity, existing signed PCS POST, default API version 0, fresh request salt. No extra account-password hash, service-auth reset, or additional login challenge is present in this fetch path.

## Playback implications and limits

The official browser SDK can take automatically recovered plaintext password via its internal `devLoginPassword` default. Its credential resolver uses an explicitly entered `code` only when nonempty; otherwise it uses that resolved password. Modes 3/5 pass this password string and device serial into native WASM `ParseDecryptKey`. This is not the same input as an already-derived `wssekey`.

A returned `playToken` plus `playTokenKey` can independently provide `devLoginName`/`devLoginPassword`. Negotiate the actual resource before rejecting solely because local password resolution is empty. A complete pair must be allowed to reach the SDK. Peer `cloud_reference` owns the SDK adapter and its synthetic WASM validation; peer `native_ui` owns wire GCM/CBC decoding and tests. This report contains static evidence only and no authorized camera playback test or account request.
