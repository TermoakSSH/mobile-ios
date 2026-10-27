# Termoak for iOS

The iOS app of [Termoak](https://termoak.com), the open-source SSH client
with an optional self-hosted server. It is SwiftUI (iOS 16+) on top of the
same Rust engine as the desktop app and the CLI, through UniFFI, with
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) as the terminal
emulator.

## Features

The same as the Android app:

- **Accounts**: several at once, on the official server or your own, with
  in-app sign-up. The app also works without a server, only on the device.
- **Vaults** shared with people and teams (Editor or Use only), with sync.
- **Hosts**: search, groups, favorites, multi-select and a full editor,
  with logos (the detected system's or one you choose).
- **Terminal** with tabs: local SSH and Telnet, persistent server sessions,
  snippets, copy/paste, the latency in the bar, and split view with
  broadcast input on iPad. Quick connect (⌘K) takes `user@host:port` and
  `telnet://host:port` too.
- **Live session sharing**: invite by email, team or link; one person types
  at a time, with a waiting room; join with `termoak://join` links.
- **AI** with approvals, keychain, SFTP files, port forwarding and settings.
- **FIDO2 security keys** (YubiKey and other FIDO2 keys) for SSH
  (`sk-ssh-ed25519`, `sk-ecdsa-sha2-nistp256`) by NFC, in the Lightning
  port (YubiKey 5Ci) or in the USB-C port, with Yubico's
  [yubikit-swift](https://github.com/Yubico/yubikit-swift): new keys made on
  the security key, resident keys loaded from it, `id_*_sk` files imported,
  and the server's sessions confirmed on the phone. **Snippets with
  variables**: `{{host}}`, `{{user}}`, `{{date}}`… filled per host,
  `{{prompt:Branch|main}}`, `{{select:Env|dev|prod}}` and `{{secret:Token}}`.
- **Hardware keyboard and trackpad** (iPad and iPhone): Ctrl, Option as Meta
  (or for your layout's characters), ⌘. as Esc, xterm arrows and function
  keys; app shortcuts listed when ⌘ is held (⌘T/⌘K, ⌘W, ⌘⇧]/⌘⇧[, Ctrl+Tab,
  ⌘1…⌘9, ⌘F, ⌘+/⌘-/⌘0, ⌘,); arrow keys in the host list and the files;
  wheel to programs that take the mouse, drag to select, secondary click.
- **iPad desktop layout**: in full screen and in big Split View or Stage
  Manager windows the app looks and works like the desktop app: tabs on
  top (Home, one per terminal, drag to reorder), a collapsible sidebar
  (⌃⌘S) with the vault, server and app sections, hosts as cards in a grid
  with the editor in a side panel, and the desktop's terminal toolbar.
  Narrow windows keep the phone layout. Settings → Appearance → "Layout on
  wide screens" can keep the phone layout, or use the desktop one on an
  iPhone Plus or Pro Max in landscape too.

iOS cuts local connections shortly after you leave the app (the app asks for
a few minutes of grace time). For long jobs, use server sessions.

## Quick start

On a Mac with Xcode, [rustup](https://rustup.rs) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
git clone --recurse-submodules https://github.com/TermoakSSH/mobile-ios
cd mobile-ios
brew install xcodegen
xcodebuild -downloadComponent MetalToolchain   # SwiftTerm compiles Metal shaders
scripts/build-ipa.sh                           # → an unsigned .ipa in dist/ios/
```

The .ipa is **unsigned**: sign it with your own certificate (Sideloadly,
AltStore, `codesign` with a profile...). Without a signature the Keychain
does not work and the app cannot open the vault (error -34018).

## Development

This repository includes [TermoakSSH/core](https://github.com/TermoakSSH/core)
as a git submodule in `core/`, pinned to a release tag. The native engine
(`termoak-ffi`) is built from it as an xcframework, and the Swift package
`TermoakKit` comes from `core/bindings/swift`.

```sh
git submodule update --init           # in an existing clone
core/scripts/build-ios.sh debug       # the engine (once, and after every core update)
xcodegen generate                     # the Xcode project, from project.yml
open Termoak.xcodeproj
```

`Termoak.xcodeproj` is generated from `project.yml` and is not committed:
edit `project.yml` and run `xcodegen generate` again.
`scripts/build-ipa.sh` only builds the engine (release) when
`core/bindings/swift/termoak_ffiFFI.xcframework` is missing.

### Updating core

The engine binary is not versioned, so it has to be rebuilt every time the
submodule moves:

```sh
git -C core fetch --tags && git -C core checkout vX.Y.Z
core/scripts/build-ios.sh debug
git add core && git commit -m "core vX.Y.Z"
```

After a `git pull` that moves `core`, run `git submodule update` and
rebuild the engine too.

### Signing and Universal Links

`Signing.xcconfig` is the one place for the Apple Team ID
(`DEVELOPMENT_TEAM`). The app asks for the Associated Domains capability
(`Termoak/Termoak.entitlements`: `applinks:termoak.com` and
`applinks:next.termoak.com`) so `https://termoak.com/join/<token>` links open
it. A personal (free) team can't sign with that capability: empty
`CODE_SIGN_ENTITLEMENTS` in `Signing.xcconfig` to build with one. Once the
Team ID is filled in, `scripts/apple-app-site-association.sh <file>` writes
the `apple-app-site-association` the servers publish at
`/.well-known/apple-app-site-association` (public-web:
`site/.well-known/apple-app-site-association`).

### Push notifications (APNs, 0.7)

`Termoak/Model/PushNotifications.swift` (and the pure rules in
`PushRouting.swift`): for every signed-in account the app asks its server
whether it can send APNs (`pushStatus().serverApns`). Only then does it ask
for permission and register the device token on that account (debug builds
as APNs sandbox tokens); a server without APNs configured leaves it inert.
The token is unregistered before signing out of an account. Notifications:
categories `TERMOAK_APPROVAL` (Approve / Deny, which only open the app's
confirmation behind the device unlock and the app lock) and
`TERMOAK_SECURITY_KEY` (Open: the vault opens and the events socket answers
the waiting request); background pushes (`resolved`) remove the delivered
notification with that tag. Settings → Notifications: per account, which
kinds, notify while the app is open, and a test.

What Apple needs (once the Apple Developer account and its Team ID exist):

1. `DEVELOPMENT_TEAM` in `Signing.xcconfig`.
2. The App ID `com.termoak` with the **Push Notifications** capability
   (the build carries `aps-environment`: `development` in Debug,
   `production` in Release, from `APS_ENVIRONMENT` in `project.yml`); make
   the provisioning profiles again after enabling it.
3. An APNs key (Certificates, Identifiers & Profiles → Keys → +, "Apple
   Push Notifications service (APNs)"): the `.p8` file (downloadable once)
   and its Key ID go to the servers' `[push.apns]` with the Team ID and the
   bundle id (server `docs/DEPLOYMENT.md`, APNs). Never in this repository.

### Teams security (0.7)

With servers that have `teams_security` (0.7+): roles Connect only / Use /
Edit / Admin (an Admin by grant can't delete the vault); Connect only and
Strict hosts open on the device with a team certificate (the engine
certifies a key made just for it) or as server sessions; Teams → a team →
Security (the SSH CA with its fingerprint, `sshd_config` lines and the
install command as a heredoc to copy or share, rotate, disable, issued
certificates and revocation; the team policy; 2FA compliance and
principals); Settings → SSH certificates (your own CA and your
certificates); "Team certificate" authentication on hosts and groups; access
policies per vault, group and host; "Approval needed" → Request access,
waiting, and the terminal connects by itself when the window opens
(countdown, every second in the last two minutes); Settings → Access
(requests to decide with a shorter window and a note, deny with a reason,
end windows early, your requests); `access_request` / `access_decided`
notifications only open that screen; reveal/export, the AI and the network
picker hidden where the team forbids them; "Recorded"; vault recordings with
a player; the 2FA banner. Code: `Model/AccessRules.swift` (pure, unit
tested), `Model/AccessBook.swift`, `Views/AccessViews.swift`,
`Views/TeamSecurityViews.swift`, `Views/AccessPolicyViews.swift`.

### End-to-end encrypted vaults, SSO and the audit (0.7)

With servers that have `features.e2ee`, `sso` and `audit_v2`: Settings →
Security sets up the account's E2EE key (optional passphrase; the 24-word
recovery phrase shown once in a numbered grid, hidden while the app is not
in front or the screen is recorded or mirrored, with copy for this device
only, save to Files and print; then three words typed back), unlocks this
device with the passphrase, the recovery phrase (live feedback and word
suggestions) or another device (the same six-digit code on both), approves
your other devices, locks, changes or removes the passphrase, makes a new
phrase, replaces the key or resets it (Face ID / Touch ID first for the
last three); the engine keeps the key in the account store sealed with the
Keychain-protected device key. Vault → Encryption (turn on with each
member's fingerprint, confirm members waiting, rotate, also by itself when
someone lost access, turn off), badges and Home banners, the private
networks warning; server sessions and host tests of an E2EE host ask
before sending its credentials for that connection. Sign-in offers
"Continue with <team>" in `ASWebAuthenticationSession` (callback scheme
`termoak`, back to `termoak://sso`, PKCE, the 2FA step); `sso_required`
switches to it; linked identities; Teams → Single sign-on (presets,
redirect URI, domains with the TXT record to copy or share, enforcement).
Audit of your account, teams and vaults with filters and export to the
share sheet, team retention and sinks (state, test, pause, delete). Code:
`Model/E2eeRules.swift`, `Model/SsoRules.swift`, `Model/AuditRules.swift`
(pure, unit tested), `Model/E2eeBook.swift`, `Views/SecurityViews.swift`,
`Views/VaultE2eeView.swift`, `Views/SsoViews.swift`, `Views/AuditViews.swift`,
`Views/E2eeTerminalViews.swift`.

### Another server as the official one

The "official server" button signs in to `https://termoak.com`. To test
against another server (the staging server, for example), build the engine
with `TERMOAK_OFFICIAL_SERVER=https://next.termoak.com core/scripts/build-ios.sh`.
Any server also works through "Use your own server".

### Unit tests

`UnitTests/` checks the pure logic, such as what each key of a hardware
keyboard sends (`Termoak/Model/HardwareKeys.swift`), the Telnet port and
`telnet://` addresses, host logos and the layout of wide windows. The target compiles the
files it tests, so it needs neither the app nor an sshd:

```sh
xcodebuild test -project Termoak.xcodeproj -scheme Termoak -only-testing:TermoakTests \
  -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation
```

### UI tests

`UITests/` goes through the key bar, the cursor gesture and the quick access
panel against a test sshd, and saves screenshots. They only run with
`xcodebuild test` and are not part of the .ipa:

```sh
TEST_RUNNER_TEST_DIR=/path/with/client/key \
TEST_RUNNER_TEST_HOST=127.0.0.1:2222:user \
xcodebuild test -project Termoak.xcodeproj -scheme Termoak \
  -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation
```

`TEST_DIR` holds the private key `client` (the screenshots are left there)
and `TEST_HOST` is `address:port:user`.

### App Store screenshots

`scripts/screenshots.sh` (Mac, Xcode 16 or later) takes the eight App Store
screenshots on an iPhone 6.9" and an iPad 13" simulator, in English and
Spanish, dark, with the status bar at 9:41, into
`fastlane/screenshots/<language>/<device>/` (the store texts are in
`fastlane/metadata/`):

```sh
scripts/screenshots.sh                                  # everything
LANGUAGES=es-ES DEVICES=iphone scripts/screenshots.sh   # a part
```

It runs the `TermoakScreenshots` UI test (`Screenshots/`, scheme
`TermoakScreenshots`, Release) with the app in demo mode: the launch argument
`-TermoakDemo YES` (only Xcode or `xcodebuild` pass it; without it the demo
code does nothing) opens an engine on an empty temporary folder, never the
vault or the Keychain, with the made-up accounts, hosts, AI, sessions,
terminals and files of `Termoak/Demo/`, and no network at all.
`-TermoakDemoScene hosts|terminal|split|copilot|ai|files|editor|vaults|themes`
chooses where it starts (Xcode: Edit Scheme → Run → Arguments, to look at a
screen by hand).

### Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Hundreds of `cannot find 'uniffi_termoak_ffi_checksum_…' in scope` | The engine xcframework is older than the bindings in `core/`. Run `core/scripts/build-ios.sh debug`. |
| `Validate plug-in "SwiftTermBuildInfoPlugin"` fails | SwiftTerm's build plugin needs to be trusted: accept it in Xcode, or pass `-skipPackagePluginValidation` to `xcodebuild`. |
| Metal shader errors while building SwiftTerm | `xcodebuild -downloadComponent MetalToolchain` |
| The app cannot open the vault (error -34018) | The app is not signed, so the Keychain is unavailable. Sign the .ipa. |

## Releases

The app is released as the `ios-vX.Y.Z` GitHub release (`MARKETING_VERSION`
in `project.yml`), with the unsigned `.ipa`:

```sh
scripts/release-local.sh version ios X.Y.Z   # also bumps the build number
scripts/release-local.sh build ios           # on a Mac: dist/ios/
scripts/release-local.sh publish ios         # without a build, it creates the release empty
```

## Documentation

- [Mobile apps and the FFI layer](https://github.com/TermoakSSH/core/blob/main/docs/MOBILE.md) (in core)
- [Internationalization](https://github.com/TermoakSSH/core/blob/main/docs/I18N.md): the strings are in
  `Termoak/Localizable.xcstrings`

## The Termoak repositories

| Repository | Contents |
|---|---|
| [TermoakSSH/core](https://github.com/TermoakSSH/core) | Shared crates (SSH engine, vault, API client, AI engine, FFI bindings, updates) and the `termoak` CLI |
| [TermoakSSH/server](https://github.com/TermoakSSH/server) | `termoak-server`: HTTP/WebSocket API, basic web app, deployment files |
| [TermoakSSH/desktop](https://github.com/TermoakSSH/desktop) | Desktop app (GPUI) for Windows, Linux and macOS |
| [TermoakSSH/mobile-android](https://github.com/TermoakSSH/mobile-android) | Android app (Jetpack Compose) |
| **[TermoakSSH/mobile-ios](https://github.com/TermoakSSH/mobile-ios)** | iOS app (SwiftUI) |
| [TermoakSSH/public-web](https://github.com/TermoakSSH/public-web) | Public website of termoak.com: landing, pricing and downloads |

## Contributing and translations

Bug reports, fixes, features and translations are welcome: see
[CONTRIBUTING.md](CONTRIBUTING.md). Translating Termoak into your language
needs no programming: copy the English strings file of an app, translate it
and open a pull request ([docs/I18N.md](https://github.com/TermoakSSH/core/blob/main/docs/I18N.md)).

## License

Copyright © Ohz Digital SL.

Termoak is free software released under the
[GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0-only).

"Termoak" and the Termoak logo are trademarks of Ohz Digital SL and are not
covered by the code license: see [TRADEMARK.md](TRADEMARK.md).
