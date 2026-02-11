#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

source "$ROOT/Scripts/_lib.sh"

PROJECT=${PROJECT:-Mouth.xcodeproj}
SCHEME=${SCHEME:-Mouth}
CONFIGURATION=${CONFIGURATION:-Release}

APP_NAME=${APP_NAME:-Mouth}
TAG_PREFIX=${TAG_PREFIX:-v}
NOTARIZE_DMG=${NOTARIZE_DMG:-1}
SKIP_NOTARIZATION=${SKIP_NOTARIZATION:-0}

# If you stored credentials via:
#   xcrun notarytool store-credentials "MouthNotary" ...
# you can rely on the default profile name without exporting any env vars.
DEFAULT_NOTARYTOOL_KEYCHAIN_PROFILE=${DEFAULT_NOTARYTOOL_KEYCHAIN_PROFILE:-MouthNotary}

require_trash
require_cmd xcodebuild
require_cmd xcrun
require_cmd ditto
require_cmd hdiutil
require_cmd codesign
require_cmd spctl
require_cmd xattr
require_cmd git

TMPDIR="$(mktemp_dir /tmp/mouth-release.XXXXXX)"
LOG_DIR="$TMPDIR/logs"
mkdir -p "$LOG_DIR"

KEY_P8=""
cleanup() {
  # Keep release artifacts by default; caller may trash $TMPDIR after uploading.
  if [[ "${CLEANUP_RELEASE_DIR:-0}" == "1" ]]; then
    trash_if_exists "$TMPDIR"
  fi
  # Best-effort cleanup of temporary API key file.
  if [[ -n "$KEY_P8" ]]; then
    trash_if_exists "$KEY_P8"
  fi
}
trap cleanup EXIT

SETTINGS="$TMPDIR/build-settings.txt"
xcode_show_build_settings "$PROJECT" "$SCHEME" "$CONFIGURATION" >"$SETTINGS"

MARKETING_VERSION="$(extract_setting "$SETTINGS" MARKETING_VERSION)"
BUILD_NUMBER="$(extract_setting "$SETTINGS" CURRENT_PROJECT_VERSION)"
TEAM_ID="$(extract_setting "$SETTINGS" DEVELOPMENT_TEAM)"
PRODUCT_BUNDLE_IDENTIFIER="$(extract_setting "$SETTINGS" PRODUCT_BUNDLE_IDENTIFIER)"

[[ -n "$MARKETING_VERSION" ]] || err "Could not extract MARKETING_VERSION."
[[ -n "$BUILD_NUMBER" ]] || err "Could not extract CURRENT_PROJECT_VERSION."
[[ -n "$TEAM_ID" ]] || err "Could not extract DEVELOPMENT_TEAM."
[[ -n "$PRODUCT_BUNDLE_IDENTIFIER" ]] || err "Could not extract PRODUCT_BUNDLE_IDENTIFIER."

TAG="${TAG_PREFIX}${MARKETING_VERSION}"

ARCHIVE="$TMPDIR/${SCHEME}.xcarchive"
EXPORT_DIR="$TMPDIR/export"
EXPORT_OPTS="$TMPDIR/exportOptions.plist"

cat >"$EXPORT_OPTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>teamID</key>
  <string>${TEAM_ID}</string>
  <key>signingStyle</key>
  <string>automatic</string>
</dict>
</plist>
PLIST

run_logged "$LOG_DIR/xcodebuild-archive.log" \
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  SKIP_INSTALL=NO \
  MOUTH_SPARKLE_FEED_URL="${MOUTH_SPARKLE_FEED_URL:-}" \
  MOUTH_SPARKLE_PUBLIC_ED_KEY="${MOUTH_SPARKLE_PUBLIC_ED_KEY:-}" \
  archive

run_logged "$LOG_DIR/xcodebuild-export.log" \
  xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_OPTS" \
  -exportPath "$EXPORT_DIR" \
  MOUTH_SPARKLE_FEED_URL="${MOUTH_SPARKLE_FEED_URL:-}" \
  MOUTH_SPARKLE_PUBLIC_ED_KEY="${MOUTH_SPARKLE_PUBLIC_ED_KEY:-}"

APP_PATH="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.app' -print -quit)"
[[ -n "$APP_PATH" ]] || err "Export did not produce an .app at $EXPORT_DIR"

# Basic signing sanity before notarization.
codesign --verify --deep --strict --verbose=4 "$APP_PATH" >/dev/null 2>&1 || err "codesign verification failed for exported app."

# Ensure no extended attributes leak into archives (can create AppleDouble files later).
xattr -cr "$APP_PATH" || true
while IFS= read -r -d '' f; do
  trash --stopOnError "$f" >/dev/null 2>&1 || true
done < <(find "$APP_PATH" -name '._*' -print0 2>/dev/null || true)

NOTARIZE_ZIP="$TMPDIR/${APP_NAME}Notarize.zip"
ditto --norsrc -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

NOTARY_ARGS=()
if [[ "$SKIP_NOTARIZATION" != "1" ]]; then
  if [[ -n "${NOTARYTOOL_KEYCHAIN_PROFILE:-}" ]]; then
    NOTARY_ARGS+=(--keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE")
  else
    # Prefer API-key env vars if provided; otherwise fall back to a conventional
    # keychain profile name ("MouthNotary") so local runs "just work".
    if [[ -n "${APP_STORE_CONNECT_API_KEY_P8:-}" || -n "${APP_STORE_CONNECT_KEY_ID:-}" || -n "${APP_STORE_CONNECT_ISSUER_ID:-}" ]]; then
      require_env APP_STORE_CONNECT_API_KEY_P8
      require_env APP_STORE_CONNECT_KEY_ID
      require_env APP_STORE_CONNECT_ISSUER_ID

      KEY_P8="$(mktemp /tmp/mouth-notary.XXXXXX.p8)"
      echo "$APP_STORE_CONNECT_API_KEY_P8" | sed 's/\\n/\n/g' >"$KEY_P8"
      NOTARY_ARGS+=(--key "$KEY_P8" --key-id "$APP_STORE_CONNECT_KEY_ID" --issuer "$APP_STORE_CONNECT_ISSUER_ID")
    else
      NOTARYTOOL_KEYCHAIN_PROFILE="$DEFAULT_NOTARYTOOL_KEYCHAIN_PROFILE"
      NOTARY_ARGS+=(--keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE")
    fi
  fi

  run_logged "$LOG_DIR/notary-submit-appzip.log" \
    xcrun notarytool submit "$NOTARIZE_ZIP" --wait "${NOTARY_ARGS[@]}"

  run_logged "$LOG_DIR/staple-app.log" \
    xcrun stapler staple "$APP_PATH"

  run_logged "$LOG_DIR/staple-validate-app.log" \
    xcrun stapler validate "$APP_PATH"

  run_logged "$LOG_DIR/spctl-app.log" \
    spctl -a -t exec -vv "$APP_PATH"
else
  echo "SKIP_NOTARIZATION=1: skipping notarytool + stapler + spctl checks"
fi

ZIP_OUT="$TMPDIR/${APP_NAME}-${MARKETING_VERSION}.zip"
ditto --norsrc -c -k --keepParent "$APP_PATH" "$ZIP_OUT"

# Package dSYM from the xcarchive.
DSYM_DIR="$ARCHIVE/dSYMs"
DSYM_PATH="$(find "$DSYM_DIR" -maxdepth 1 -name '*.dSYM' -print -quit 2>/dev/null || true)"
DSYM_ZIP_OUT="$TMPDIR/${APP_NAME}-${MARKETING_VERSION}.dSYM.zip"
if [[ -n "$DSYM_PATH" ]]; then
  ditto --norsrc -c -k --keepParent "$DSYM_PATH" "$DSYM_ZIP_OUT"
fi

# DMG: stage app + /Applications symlink.
DMG_STAGE="$TMPDIR/dmg-stage"
mkdir -p "$DMG_STAGE"
ditto "$APP_PATH" "$DMG_STAGE/${APP_NAME}.app"
ln -s /Applications "$DMG_STAGE/Applications"

DMG_OUT="$TMPDIR/${APP_NAME}-${MARKETING_VERSION}.dmg"
hdiutil create -fs HFS+ -volname "$APP_NAME" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG_OUT" >/dev/null

if [[ "$NOTARIZE_DMG" == "1" ]]; then
  if [[ -n "${DMG_SIGN_IDENTITY:-}" ]]; then
    codesign --force --timestamp --sign "$DMG_SIGN_IDENTITY" "$DMG_OUT"
  fi

  if [[ "$SKIP_NOTARIZATION" != "1" ]]; then
    run_logged "$LOG_DIR/notary-submit-dmg.log" \
      xcrun notarytool submit "$DMG_OUT" --wait "${NOTARY_ARGS[@]}"

    run_logged "$LOG_DIR/staple-dmg.log" \
      xcrun stapler staple "$DMG_OUT"

    run_logged "$LOG_DIR/staple-validate-dmg.log" \
      xcrun stapler validate "$DMG_OUT"

    # `spctl --assess --type open` frequently returns "rejected / Insufficient Context"
    # for DMGs even when notarization + stapling succeeded. Prefer stapler validation
    # as the source of truth, and treat Insufficient Context as non-fatal.
    SPCTL_DMG_LOG="$LOG_DIR/spctl-dmg.log"
    set +e
    spctl -a -t open -vv "$DMG_OUT" >"$SPCTL_DMG_LOG" 2>&1
    SPCTL_DMG_STATUS=$?
    set -e
    if [[ $SPCTL_DMG_STATUS -ne 0 ]]; then
      if rg -n "source=Insufficient Context" -S "$SPCTL_DMG_LOG" >/dev/null 2>&1; then
        echo "NOTE: spctl DMG assessment returned 'Insufficient Context' (ignored); notarization + stapling were successful."
      else
        echo "Command failed (exit $SPCTL_DMG_STATUS): spctl -a -t open -vv $DMG_OUT" >&2
        echo "Log: $SPCTL_DMG_LOG" >&2
        cat "$SPCTL_DMG_LOG" >&2 || true
        exit $SPCTL_DMG_STATUS
      fi
    fi
  fi
fi

# Export machine-readable outputs for Scripts/release.sh.
OUT_ENV="$TMPDIR/outputs.env"
cat >"$OUT_ENV" <<EOF
RELEASE_DIR=$TMPDIR
TAG=$TAG
MARKETING_VERSION=$MARKETING_VERSION
BUILD_NUMBER=$BUILD_NUMBER
BUNDLE_ID=$PRODUCT_BUNDLE_IDENTIFIER
APP=$APP_PATH
ZIP=$ZIP_OUT
DMG=$DMG_OUT
DSYM_ZIP=$DSYM_ZIP_OUT
EOF

cp "$OUT_ENV" /tmp/mouth-last-release-outputs.env

echo "Release artifacts prepared in: $TMPDIR"
echo "Outputs file: $OUT_ENV"
