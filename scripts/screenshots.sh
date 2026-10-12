#!/usr/bin/env bash
# App Store screenshots, on a Mac with Xcode 16 or later: runs the
# TermoakScreenshots UI test (Screenshots/ScreenshotTests.swift) with the app
# in demo mode (Termoak/Demo/: made-up hosts, AI, sessions and files; no
# server, sshd or network) on an iPhone 6.9" and an iPad 13" simulator, in
# English and Spanish, dark, with the status bar at 9:41, and copies the
# screenshots to fastlane/screenshots/<language>/<device>/01_hosts.png…
#
#   scripts/screenshots.sh
#   LANGUAGES=es-ES DEVICES=ipad scripts/screenshots.sh
#
# Variables:
#   LANGUAGES     App Store languages (default: "en-US es-ES")
#   DEVICES       iphone and/or ipad (default: "iphone ipad")
#   IPHONE_MODEL  simulator for the 6.9" ones, 1320×2868 (default: iPhone 16 Pro Max)
#   IPAD_MODEL    simulator for the 13" ones, 2064×2752 (default: iPad Pro 13-inch (M4))
#   KEEP_RESULTS  1: keep the .xcresult bundles in target/screenshots/
#
# A simulator of each model is created (xcrun simctl create) if there is
# none. Close Simulator.app first, or untick its I/O → Keyboard → Connect
# Hardware Keyboard, so the on-screen keyboard (with the key bar) shows.
#
# Compatible with macOS's bash 3.2.
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
  echo "scripts/screenshots.sh requires macOS with Xcode" >&2
  exit 1
fi
command -v xcodegen >/dev/null || { echo "XcodeGen is missing: brew install xcodegen" >&2; exit 1; }
if ! xcrun xcresulttool export attachments --help >/dev/null 2>&1; then
  echo "xcresulttool can't export attachments: Xcode 16 or later is needed" >&2
  exit 1
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

LANGUAGES="${LANGUAGES:-en-US es-ES}"
DEVICES="${DEVICES:-iphone ipad}"
IPHONE_MODEL="${IPHONE_MODEL:-iPhone 16 Pro Max}"
IPAD_MODEL="${IPAD_MODEL:-iPad Pro 13-inch (M4)}"
work="$root/target/screenshots"
out="$root/fastlane/screenshots"

say() { printf '\n==> %s\n' "$*"; }

# ----- The engine and the project (like scripts/build-ipa.sh) -----

if [ ! -f core/scripts/build-ios.sh ]; then
  echo "the core submodule is missing: git submodule update --init" >&2
  exit 1
fi
xcf=core/bindings/swift/termoak_ffiFFI.xcframework
stamp="$root/target/ios-engine.commit"
core_commit="$(git -C core rev-parse HEAD):${TERMOAK_OFFICIAL_SERVER:-}"
if [ ! -d "$xcf" ] || [ "${REBUILD_ENGINE:-0}" = 1 ] || [ "$(cat "$stamp" 2>/dev/null)" != "$core_commit" ]; then
  say "engine (core $(git -C core describe --tags --always))"
  core/scripts/build-ios.sh release
  mkdir -p "$(dirname "$stamp")"
  echo "$core_commit" >"$stamp"
fi

xcodegen generate --quiet
rm -rf "$work/results"
mkdir -p "$work/results" "$work/logs"

say "build (Release, simulator)"
if ! xcodebuild build-for-testing \
  -project Termoak.xcodeproj \
  -scheme TermoakScreenshots \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$work/DerivedData" \
  -skipPackagePluginValidation -skipMacroValidation \
  >"$work/logs/build.log" 2>&1; then
  grep -E "error:" "$work/logs/build.log" | sort -u || true
  echo "the build failed (full log: ${work#"$root"/}/logs/build.log)" >&2
  exit 1
fi

# ----- Simulators -----

# UDID of the newest available simulator called exactly "$1", created if missing.
simulator() {
  local name="$1" udid
  udid="$(xcrun simctl list devices available | grep -F "    $name (" | tail -1 \
    | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')"
  if [ -z "$udid" ]; then
    udid="$(xcrun simctl create "$name" "$name")"
  fi
  echo "$udid"
}

# Language, region and keyboard of the whole simulator (its keyboard and
# system texts too), then a clean boot, dark, with the status bar at 9:41.
prepare() {
  local udid="$1" language="$2" locale="$3" keyboard="$4"
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl spawn "$udid" defaults write -g AppleLanguages -array "$language"
  xcrun simctl spawn "$udid" defaults write -g AppleLocale -string "$locale"
  xcrun simctl spawn "$udid" defaults write -g AppleKeyboards -array "$keyboard" "emoji@sw=Emoji"
  xcrun simctl shutdown "$udid"
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl ui "$udid" appearance dark
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3
  # A fresh install: nothing left from earlier runs.
  xcrun simctl uninstall "$udid" com.termoak >/dev/null 2>&1 || true
}

# Copies the attachments of result bundle $1 to folder $2 by their names
# (01_hosts…): xcresulttool exports them with a manifest.json.
extract() {
  local result="$1" dest="$2" tmp manifest i j name file base
  tmp="$(mktemp -d)"
  xcrun xcresulttool export attachments --path "$result" --output-path "$tmp" >/dev/null
  manifest="$tmp/manifest.json"
  rm -rf "$dest"
  mkdir -p "$dest"
  i=0
  while plutil -extract "$i" json -o /dev/null "$manifest" >/dev/null 2>&1; do
    j=0
    while name="$(plutil -extract "$i.attachments.$j.suggestedHumanReadableName" raw -o - "$manifest" 2>/dev/null)"; do
      file="$(plutil -extract "$i.attachments.$j.exportedFileName" raw -o - "$manifest")"
      # "01_hosts_0_<UUID>.png" → "01_hosts"
      base="$(printf '%s' "$name" | sed -E 's/_[0-9]+_[0-9A-Fa-f-]{36}(\.[A-Za-z0-9]+)?$//; s/\.[A-Za-z0-9]+$//')"
      case "$base" in
        [0-9][0-9]_*) cp "$tmp/$file" "$dest/$base.png" ;;
      esac
      j=$((j + 1))
    done
    i=$((i + 1))
  done
  rm -rf "$tmp"
}

failures=""
summary=""

for device in $DEVICES; do
  case "$device" in
    iphone) model="$IPHONE_MODEL"; folder="iPhone 6.9"; size="1320x2868" ;;
    ipad) model="$IPAD_MODEL"; folder="iPad 13"; size="2064x2752" ;;
    *) echo "unknown device: $device (iphone or ipad)" >&2; exit 1 ;;
  esac
  udid="$(simulator "$model")"
  for store in $LANGUAGES; do
    case "$store" in
      en-US) language=en; locale=en_US; keyboard="en_US@sw=QWERTY;hw=Automatic" ;;
      es-ES) language=es; locale=es_ES; keyboard="es_ES@sw=QWERTY-Spanish;hw=Automatic" ;;
      *) echo "unknown language: $store (en-US or es-ES)" >&2; exit 1 ;;
    esac
    say "$folder, $store ($model, $udid)"
    prepare "$udid" "$language" "$locale" "$keyboard"
    result="$work/results/$store-$device.xcresult"
    log="$work/logs/$store-$device.log"
    status=0
    TEST_RUNNER_SCREENSHOT_LANGUAGE="$language" TEST_RUNNER_SCREENSHOT_LOCALE="$locale" \
      xcodebuild test-without-building \
      -project Termoak.xcodeproj \
      -scheme TermoakScreenshots \
      -configuration Release \
      -destination "platform=iOS Simulator,id=$udid" \
      -derivedDataPath "$work/DerivedData" \
      -resultBundlePath "$result" \
      -skipPackagePluginValidation -skipMacroValidation \
      >"$log" 2>&1 || status=$?
    if [ "$status" != 0 ]; then
      failures="$failures $store/$device"
      grep -E "error:|failed|“" "$log" | sort -u | head -20 || true
    fi
    dest="$out/$store/$folder"
    if [ -d "$result" ]; then extract "$result" "$dest"; fi
    count=0
    for png in "$dest"/*.png; do
      [ -f "$png" ] || continue
      count=$((count + 1))
      w="$(sips -g pixelWidth "$png" | awk '/pixelWidth/ {print $2}')"
      h="$(sips -g pixelHeight "$png" | awk '/pixelHeight/ {print $2}')"
      note=""
      [ "${w}x${h}" = "$size" ] || note="  (expected $size)"
      summary="$summary
  $store/$folder/$(basename "$png")  ${w}x${h}$note"
    done
    summary="$summary
  → $store/$folder: $count screenshots"
    xcrun simctl status_bar "$udid" clear >/dev/null 2>&1 || true
  done
  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
done

[ "${KEEP_RESULTS:-0}" = 1 ] || rm -rf "$work/results"

say "screenshots in ${out#"$root"/}/"
printf '%s\n' "$summary"
if [ -n "$failures" ]; then
  echo
  echo "some screens did not show up in:$failures (logs in ${work#"$root"/}/logs/)" >&2
  exit 1
fi
