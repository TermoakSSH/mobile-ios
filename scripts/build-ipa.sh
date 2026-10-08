#!/usr/bin/env bash
# Builds the iOS app and creates an UNSIGNED .ipa in dist/ios/.
# Users sign it afterwards with their own certificate (Sideloadly, AltStore,
# `codesign` + provisioning profile...).
#
# Requirements: macOS with Xcode, rustup and XcodeGen (`brew install xcodegen`).
# The engine xcframework is built with core/scripts/build-ios.sh when it is
# missing or out of date (core/ is the TermoakSSH/core submodule).
#
# Usage: scripts/build-ipa.sh
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
  echo "scripts/build-ipa.sh requires macOS with Xcode" >&2
  exit 1
fi
command -v xcodegen >/dev/null || { echo "XcodeGen is missing: brew install xcodegen" >&2; exit 1; }

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [ ! -f core/scripts/build-ios.sh ]; then
  echo "the core submodule is missing: git submodule update --init" >&2
  exit 1
fi
# The engine is rebuilt when it is missing or was built from another core
# commit (after `git submodule update` or a new core tag), or with
# REBUILD_ENGINE=1 (e.g. after changing TERMOAK_OFFICIAL_SERVER).
xcf=core/bindings/swift/termoak_ffiFFI.xcframework
stamp="$root/target/ios-engine.commit"
core_commit="$(git -C core rev-parse HEAD):${TERMOAK_OFFICIAL_SERVER:-}"
if [ ! -d "$xcf" ] || [ "${REBUILD_ENGINE:-0}" = 1 ] || [ "$(cat "$stamp" 2>/dev/null)" != "$core_commit" ]; then
  echo "==> engine (core $(git -C core describe --tags --always))"
  core/scripts/build-ios.sh release
  mkdir -p "$(dirname "$stamp")"
  echo "$core_commit" >"$stamp"
fi

xcodegen generate --quiet

version="$(sed -n '/MARKETING_VERSION:/{s/.*"\(.*\)"/\1/p;q;}' project.yml)"
work="$root/target/ios-app"
archive="$work/Termoak.xcarchive"
rm -rf "$work"
mkdir -p "$work"

echo "==> xcodebuild archive (unsigned)"
xcodebuild archive \
  -project Termoak.xcodeproj \
  -scheme Termoak \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive" \
  -derivedDataPath "$work/DerivedData" \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  > "$work/xcodebuild.log" 2>&1 || true
grep -E "error:|\*\* ARCHIVE" "$work/xcodebuild.log" | sort -u || true

app="$archive/Products/Applications/Termoak.app"
[ -d "$app" ] || { echo "the app was not built (full log: ${work#"$root"/}/xcodebuild.log)" >&2; exit 1; }

mkdir -p "$work/Payload" dist/ios
cp -R "$app" "$work/Payload/"
ipa="$root/dist/ios/Termoak-${version}-unsigned.ipa"
rm -f "$ipa"
(cd "$work" && zip -qry "$ipa" Payload)

echo "Done: ${ipa#"$root"/} ($(du -h "$ipa" | cut -f1))"
