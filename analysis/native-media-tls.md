# Native media TLS static evidence

Binary `analysis/installer/bin/StreamPCSDKmd.dll`, SHA256 `abaa4cb9b280ac042e32f65ab93d591e73ca25b8ab668f6b0bc5b39a069daa9a`. VA base0x180000000; text rawoffset=VA-0x180000c00. Static analysis only: no TLS probe/account request performed by this worker. Runtime parent reports NSURLErrorSecureConnectionFailed -1200, but underlying numeric SSL failure is not yet available. This generic code does not establish a certificate failure, protocol failure or cipher failure.

## Chain and settings

CDHHTTPClient::getStream maps isTls to sockettype1 and init_http_client0x1804bc800 forwards to CHttpClientWrapper::init_http_client0x1804fbf80. Type1 dispatches message8 (0x1804fc25d) to media session. CHttpClientSessionImpl::init_internal0x1804ec690 routes types3/8 through TLS branch0x1804ecbfc, constructing CSslAsyncStream0x180471ee0, optional SetPemPath0x180472030 at0x1804eccf2 when extra PEM argument r13 is nonnull, then Connect0x180472150 at0x1804ecda4. Constructor471ee0 constructs CProxyHandler0x18046cb80. The latter allocates its state atthis+10, and memset(state+60,0,0x80) at0x18046cc33..43: default verifyflags+70=0, certobject+78=null, protocol-disablemask+80=0, customcipher+90=0, SNI+c8=null.

CProxyHandler::initSslSession0x180470230 -> init_ssl_ctx0x180471a60 -> generic TLS method getter0x1802f5610 and SSL_CTX_new0x1802e9e80. The method table0x180907280 begins version0x10000 (TLS_ANY_VERSION), not pinned TLS1.2/1.3. No explicit minimum/maximum TLS version control found in this path. Protocol maskstate+80 conditionally sets SSL options 0,0x02000000,0x04000000,0x10000000 at0x180471e50; initialized0 means none applied. This permits legacy versions in the original library; it does not prove which version the actual relay requires.

Default cipher list passed to SSL_set_cipher_list0x1802ec440 at0x1804704e1 is:

`ALL:!COMPLEMENTOFDEFAULT:!eNULL:!DES:!RC4:!3DES`

If state+90==1, a custom cipher rule pointerstate+98 is used instead (0x1804705e9). No ordinary-path PSK callback or fixed PSK cipher selection found. No automatic client certificate installed without optional PEM/cert configuration. This finding does not establish that a server requests a client certificate.

SNI is explicit/optional: state+c8 nonnull -> SSL_ctrl0x1802ea7c0(cmd55,arg0,servername) at0x18047070f. A bare IP is not automatically changed to a DNS hostname in this function. The source of an optional media SNI setting is not yet proven.

## Trust mechanism and limitations

certificate_setup0x180470fc0 reads state+70 flags and state+78 certificateobject. Bit1 enables SSL_CTX_set_verify(ctx,1,nullcallback)0x1802ea4b0 at0x180471026; when certificateobject exists, its X509 cert stack is added to SSL_CTX_get_cert_store0x1802e9e60 / X509_STORE_add_cert0x1802e50b0 at0x180471066..71. Bit2 gates optional clientcertificate/privatekey setup. When state+0x40 PEMpath is nonnull, PEM-path fallback constructs `%s/cacert.pem` and `%s/privkey.pem` (0x180471606/623). Thus generic SDK supports custom anchors and client certs, but the exact configured media caller extra PEM pointer is not yet resolved. It would be incorrect to claim Ims_Root_CA.pem is definitely used by this media socket solely because it ships with the app.

Default unconfigured peer verification appears disabled in the native OpenSSL client; copying that behavior into macOS would weaken validation and is not proposed. Secure compatibility should preserve chain/hostname validation and only use a verified vendor trust anchor / correct server name when supported by actual chain and caller evidence. Wait for the underlying SSL numeric error before deciding whether trust, SNI, versions or ciphers are responsible.

Evidence files: stream-native-tls-client-init-annotated.asm, stream-native-tls-wrapper-init-annotated.asm, stream-native-http-tls-init-annotated.asm, stream-native-tls-socket-api-annotated.asm, stream-native-tls-proxy-ctor-annotated.asm, stream-native-tls-session-annotated.asm, stream-native-tls-context-annotated.asm, stream-native-tls-trust-annotated.asm. Some broad ranges include padding or subsequent functions; named addresses above are relevant aligned boundaries.

## Bounded follow-up after actual peer trust diagnosis

Parent's authorized runtime diagnosis of the app's own TLS attempt now establishes `SecTrust` -67602 / stream SSL -9802, with SSLHostname and TemporalValidity failures (leaf and intermediate). Redacted peer DER SHA256 values supplied by parent: `f7b3d7133ffd45b44b61b4c5b22192ae2a9fe4c346ea941308c656fe698bbbf2`, `bfdf4cf3f143ad0db912d8ab3a7c12f617b9ea60ce8b1f4e44f74270fb21b19b`, `ebd41040e4bb3ec742c9e381d31ef2a41a48b6685c96e7cef3c1df6cd4331c99`. This worker did not fetch or inspect live certificates.

Existing bounded Windows evidence yields no proven secure alias/host repair for that endpoint:

- GetRealTransferStreamUrl0x1800c23f0 consumes only response.data.resource or response.data.tls_resource at0x1800c42cb..c43b7, copies selected string to output. No certificate, DNS identity or SNI field is read. See stream-getreal-pseudocode.c and stream-getreal-annotated.asm.
- createHttpCamera0x180167650 parses host/port directly from returned authority, keeps first-slash suffix. No mapping IP->trustedDNSalias or alternate TLS authority was found.
- Optional MQTT service96500 similarly selects output96523(TLS) or96521(nonTLS), one opaque resource string. It supplies no independent certificate identity in this function.
- LoginStream loginRemoteServersDetails0x1800bf320 creates host/IP-specific PCS client from its explicit configured server descriptor, sends /pcs/v1/things.media.LoginStream with data{} and checks HTTP200. It does not read a certificate hostname or media alias from response.
- The native supported alternative negotiation is data.type=`RTSP` (protocol!=1), with TLS resource selection stilltrue, instead of data.type=`RTSV1`(protocol1). This is a real authenticated API alternative, not a guessed hostname. It might allocate a different legitimate relay/port; existing static evidence cannot establish a valid certificate there or player compatibility with any returned resource. This worker made no new negotiation request.

Adding a bundled root or substituting SNI alone cannot remove the observed TemporalValidity failures in leaf and intermediate. Keeping normal chain, name and time validation means the current invalid chain must be rejected. Native unconfigured OpenSSL verification defaults explain how Windows may accept this endpoint; they do not provide a safe macOS equivalent. The server must present a valid certificate chain/identity, or an independently authenticated API route must supply a different valid endpoint. No such guaranteed endpoint was recovered in this bounded static check.
