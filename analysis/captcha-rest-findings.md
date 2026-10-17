# CAPTCHA REST schema evidence

Static inspection only; no account, CAPTCHA validation, SMS, email, or other network requests were sent.

Target `analysis/installer/bin/RestApimd.dll`, SHA-256 `7aff27e0199c3182f1d630e7d95bc0084b787918f9014d4a968d7d27e185981f`. REA/Ghidra 12.1.4, default analysis profile digest `2f8e96b5753c9076371d59a3c3682f610a66fa4834dc6dc5f556e707a6b8c2cf`.

Root/native-UI investigation establishes HTTP API code 12114 maps to native 35, then the Windows login dialog creates LCGeeTest for a user-completed CAPTCHA. This worker's bounded responsibility is the REST schema and generic signer.

## GeeTest 4 check

Export `hsview_api_init_commonValidcode_CheckGeeTest4Request`, VA `0x180060180` (RVA `0x60180`), builds:

- Method `common.validcode.CheckGeeTest4`.
- API version `152485`.
- JSON content type.
- Data schema contains eight **string** fields: `passToken`, `captchaId`, `captchaMetaData`, `usage`, `account`, `lotNumber`, `genTime`, `captchaOutput`.
- It selects the normal SaaS request signer; no challenge-specific signing callback occurs in this initializer.

Full Evidence `ev_526806249003df1acc37832f908a6f2fb76ecff78ea1188978ec50f43173651c` is saved in `analysis/captcha-check4-request.json`, readable decompile `analysis/captcha-check4-request.c`.

Export `hsview_api_init_commonValidcode_CheckGeeTest4Response`, VA `0x180060370` (RVA `0x60370`), describes a single string field `token`. The same response schema is shared with legacy GeeTest/image-code checks and an OAuth-code response; this sharing does not make the token types interchangeable.

Full Evidence `ev_75dc7018d8509f67ed185ad62de8efd7bcebfe731cccf3daba1e584297ee06b1` is saved in `analysis/captcha-check4-response.json`, readable decompile `analysis/captcha-check4-response.c`.

## Legacy GeeTest fetch (instruction evidence)

`hsview_api_init_commonValidcode_GetGeeTestValidCodeRequest` RVA `0x60950` describes string fields `usage` and `account`. Response RVA `0x60a70` describes string fields `gtServerStatus`, `challenge`, and `gt`. It is a distinct legacy API; do not substitute this flow for a server-selected GeeTest 4 challenge.

## Signer boundary and unknown handoff

Complete normal `saas_request_sign` decompile inspected under Evidence `ev_1a88e81abedabc065cf2e5ecc081d7f351dce1818800fc5ac9af288e31d164e6`. Its observed headers are the ordinary x-pcs username, date, nonce, api version, client UA, optional session ID, body hashes and signatures, and optional region. There is no GeeTest/CAPTCHA-specific header or token setter in this function. The existing root investigation already owns this signer implementation.

Bounded case-insensitive raw-string/export search in RestApimd also found no dedicated captcha/risk token client setter. This does not establish that a generic header API or another library cannot attach a ticket.

LCCommon.dll separately contains a modern signer format including `x-pcs-token:%s`, but this alone does **not** establish that its token is the CheckGeeTest4 validation token. The native-UI worker owns the LCGeeTest callback and retry handoff, and must resolve that field's actual use before implementation.

The authorized app flow should display the official challenge for the user to complete, submit the returned challenge output through the exact CheckGeeTest4 flow, and attach only the actual server-issued validation result as recovered from the native callback. No CAPTCHA solving or bypass was attempted.

Session snapshot `analysis/captcha-rest-snapshot.json` retains this evidence and the imported existing REST investigation. Shared REA was closed successfully after a transient cleanup ownership-check error on the first close; a subsequent close returned result null.

## Modern LCCommon caller supersedes legacy schema assumptions

Native-UI worker subsequently recovered the actual modern request caller at LCCommon VA `0x180006de0`. It adds `isEncrypt:true`, a GCM-encrypted `account`, and optional `verifyToken` taken from the original failure's `data.captchaData.verifyToken`, in addition to the eight legacy schema fields. Usage is `Login`.

Its success callback at LCCommon VA `0x1800078d0`, Evidence `ev_b0109b954cdbec06bd471f701153fc4ccf572a6c5431e5d98df378a58e3ac8fc`, checks status `success`, hides the dialog, and emits `LCGeeTest::signalSuccess`. It does **not** read `response.token` or install a ticket/header. Consequently the legacy response initializer above does not justify adding a validation-token header to the login retry. The modern native caller and original challenge context are the implementation authority; native-UI worker retains its full evidence and is tracing encryption and the official page URL.
