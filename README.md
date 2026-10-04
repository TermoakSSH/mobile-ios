# Termoak for iOS

The iOS app of [Termoak](https://termoak.com), the open-source SSH client
with an optional self-hosted server: SwiftUI on top of the same Rust engine
as the desktop app and the CLI (through UniFFI).

The app is SwiftUI, iOS 15+, with
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) as the terminal
emulator). It has the same features as the Android app: sign-in and sync,
hosts (search, groups, favorites, full editor), a tabbed terminal (local SSH
and persistent server sessions, snippets, copy/paste), server sessions, AI
with approvals, keychain, snippets and settings. iOS cuts local connections
shortly after you leave the app (a few minutes of grace time are requested);
for long jobs, use server sessions. The Xcode project is generated with
[XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`
and is not committed.

```sh
brew install xcodegen
xcodebuild -downloadComponent MetalToolchain   # SwiftTerm compiles Metal shaders
scripts/build-ipa.sh      # → an unsigned .ipa in dist/ios/
```

The .ipa is **unsigned**: sign it with your own certificate (Sideloadly,
AltStore, `codesign` with a profile...). Without a signature the Keychain
does not work and the app cannot open the vault (error -34018).

## Building

This repository includes [TermoakSSH/core](https://github.com/TermoakSSH/core) as a git submodule in
`core/`, pinned to a release tag: the native engine (`termoak-ffi`) is built
from it and the bindings come from its `bindings/` folder.

```sh
git clone --recurse-submodules https://github.com/TermoakSSH/mobile-ios
# or, in an existing clone:
git submodule update --init
```

To move to a newer core:

```sh
git -C core fetch --tags && git -C core checkout v0.2.1
git add core && git commit -m "Core 0.2.1"
```

Requirements: macOS with Xcode, [rustup](https://rustup.rs) and XcodeGen.
`scripts/build-ipa.sh` builds the engine with `core/scripts/build-ios.sh` if
`core/bindings/swift/termoak_ffiFFI.xcframework` is missing (delete it to
rebuild the engine), generates the Xcode project and creates the `.ipa`. For
day-to-day work, run `core/scripts/build-ios.sh debug` once, then
`xcodegen generate` and open `Termoak.xcodeproj`.

## Releases

The app is released as the `ios-vX.Y.Z` GitHub release (`MARKETING_VERSION`
in `project.yml`), with the unsigned `.ipa`:

```sh
scripts/release-local.sh version ios 0.3.5   # also bumps the build number
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
