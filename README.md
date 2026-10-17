<p align="center">
  <img src="docs/logo.png" width="128" height="128" alt="Imou Glance icon">
</p>

<h1 align="center">Imou Glance</h1>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15.2%2B-000000?logo=apple&logoColor=white" alt="macOS 15.2+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-555555" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/UI-AppKit%20%C2%B7%20Liquid%20Glass-F06620" alt="AppKit with Liquid Glass">
  <img src="https://img.shields.io/badge/Unofficial-B42318" alt="Unofficial">
  <a href="https://github.com/umarz317/imou-glance/releases/latest"><img src="https://img.shields.io/github/v/release/umarz317/imou-glance?label=download&color=F06620" alt="Download latest release"></a>
</p>

<p align="center">
  <b>Your Imou cameras, live from the macOS menu bar.</b>
</p>

<p align="center">
  <img src="docs/screenshots/live.webp" width="420" alt="Imou Glance menu bar popover showing one live camera with camera, quality and layout controls">
</p>

> [!IMPORTANT]
> **Unofficial.** Imou Glance is an independent personal project, **not affiliated
> with, endorsed by, or supported by Imou** or its parent companies. It uses
> reverse-engineered interfaces that Imou may change or block at any time. Use it
> at your own risk; see [Disclaimers](#disclaimers).

## Features

- **Sign in** with your Imou email or phone number, including Imou's security
  puzzle and "Authorize this Mac" step, or **scan a QR code** with the Imou Life
  app (works for accounts that use Apple or Google sign-in).
- **Watch live**, muted, one camera at a time or **two or four at once**.
- **Pick video quality** per camera from what the camera offers.
- **Recover on its own** after drops, stalls and sleep.
- **Remember** your sign-in (Keychain), last camera, quality and layout.

## Download

Requires an Apple Silicon Mac on **macOS 15.2 or later**.

1. Download **Imou-Glance-1.1.0-arm64.zip** from the
   [latest release](https://github.com/umarz317/imou-glance/releases/latest).
2. Unzip it and move **Imou Glance.app** to Applications.
3. Open it. The app is signed with a Developer ID and notarized by Apple, so it
   opens without Gatekeeper warnings.

## Build from source

Building needs Xcode with the macOS 26 SDK or newer (the glass look falls back
gracefully on older macOS).

```sh
bash scripts/build-app.sh
open "build/Imou Glance.app"
```

This makes `build/Imou Glance.app` with a local ad hoc signature. For a signed,
notarized release zip, pass a Developer ID identity and a `notarytool`
credentials profile:

```sh
SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=notary bash scripts/build-app.sh
```

## Use

1. Click the **video icon** in the menu bar.
2. Choose **Email** or **Phone** and sign in. Phone needs the country code.
3. If **Verify it's you** appears, click **Verify** and finish the puzzle.
4. If **Authorize this Mac** appears, request the code and enter it.
5. Pick a camera. Its camera password is fetched for you.

Use the **layout switch** in the header for two or four cameras; click a tile
to open it on its own. The **quality menu** on the video (or on each tile)
changes resolution.

## Good to know

- **Closing the popover stops the video.** Opening it again starts fresh streams.
- **Dropped streams reconnect automatically.** A drop, a 15-second stall or a
  player crash retries after 2, 4, 8, 16, then every 30 seconds while the camera
  is on screen. A minute of healthy video resets the wait. The app also
  reconnects right after the Mac wakes. **Reconnect** retries immediately.
- **Use one preview at a time.** The `--show` inspection window and the menu
  popover can affect each other's status.

### What is remembered

| Item | Where | Cleared by |
| --- | --- | --- |
| Account, password, country code (if **Remember me** is on) | Login Keychain, this Mac only | **Sign Out** |
| Imou session token after a QR sign-in (if **Remember me** is on) | Login Keychain, this Mac only | **Sign Out**, or Imou rejecting it |
| Last camera and per-camera quality | Preferences | **Sign Out** |
| 1 / 2 / 4 camera layout | Preferences | Never (it's a view setting) |
| Random terminal identifier | Preferences | Never |
| Session, account tokens, camera keys, stream URLs | Memory only | Quit or Sign Out |

**Quit** ends the session but keeps everything saved. Secrets are never written
to logs or ordinary files.

## Security note: relay certificate

Imou's tested relay presents an **expired certificate that doesn't match its
address**. After a successful sign-in, the app allows **that one exact
certificate** (pinned by fingerprint) until sign-out or quit. Every other
certificate still needs normal validation, and macOS trust settings are not
changed.

The connection stays encrypted, but anyone holding that certificate's private
key could impersonate the relay. Details: [reverse engineering guide, step 6](docs/reverse-engineering.md#6-connect-to-the-relay).

## Troubleshooting

| What you see | What to do |
| --- | --- |
| Account or password rejected | Check **Email** vs **Phone** and re-enter your details. |
| A security puzzle | Complete it; sign-in then continues. Imou often asks after a wrong password. |
| CAPTCHA `-50106` or validation `11010` | Rebuild from current source; older builds used the wrong CAPTCHA setup ([fix report](analysis/captcha-provider-fix.md)). |
| Black video or **Stopped** | Wait for the automatic reconnect or click **Reconnect**. If it keeps happening, note the error shown (never share a stream URL). |
| Unsupported media or encryption | That camera setup needs more protocol work. |

## Status

Verified on **17 October 2026**: live video from two cameras and a full sign-in
including the human CAPTCHA. Not yet verified: very
long sessions and other camera models.

<details>
<summary><b>Development</b></summary>

Open the UI in a regular window for inspection:

```sh
"build/Imou Glance.app/Contents/MacOS/ImouPeek" --show
```

Sign in from a local `.env` file (one literal `KEY=value` per line, no quotes,
never evaluated as shell). Keys: `IMOU_EMAIL`, `IMOU_PASSWORD`, optional
`IMOU_COUNTRY_CODE`.

```sh
"build/Imou Glance.app/Contents/MacOS/ImouPeek" --show --credentials-file "$PWD/.env"
```

`.env` is ignored by Git, never printed, and not copied to the Keychain. Keep
it private.

Run the tests (the Keychain test needs host Keychain access):

```sh
env CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
    XDG_CACHE_HOME="$PWD/.build/cache" \
    swift test --disable-sandbox --cache-path .build/cache \
    --config-path .build/config --security-path .build/security -debug-info-format none
```

Passing tests don't prove live playback.

</details>

## Further reading

- [Reverse engineering guide](docs/reverse-engineering.md): how it works, step by step, with evidence.
- [Implementation history](docs/implementation.md): research notes in order; later entries may resolve earlier limits.
- [Player asset provenance](Sources/ImouMac/PlayerAssets/PROVENANCE.txt): decoder versions and checksums.

## Disclaimers

- **Unofficial.** "Imou" names and logos are trademarks of their owners, used
  only to describe compatibility. This is not an Imou product, and Imou does
  not support it.
- **No warranty.** Provided "as is", without warranty of any kind. The authors
  aren't liable for damage, data loss, account action or missed events.
- **Not for safety-critical monitoring.** Video can drop or stop without
  notice. For security, emergencies or life safety, use Imou's official apps
  and alerts.
- **Reverse-engineered interfaces.** Sign-in, camera keys and streaming follow
  Imou's own clients. This may conflict with Imou's terms of service, and an
  Imou update can break the app. Check the terms for your account.
- **Your cameras only.** Use only accounts and cameras you own or may access,
  and follow local privacy and recording laws.
- **Security trade-offs.** The app pins one expired relay certificate (see
  [Security note](#security-note-relay-certificate)) and can store your Imou
  password, or a QR sign-in's session token, in the Keychain. Consider this on shared or managed Macs.
- **Third-party files.** The player files in `Sources/ImouMac/PlayerAssets` are
  unmodified Imou Web Video SDK assets owned by their authors; see
  [PROVENANCE.txt](Sources/ImouMac/PlayerAssets/PROVENANCE.txt).
- **Screenshots** show the author's own cameras.
