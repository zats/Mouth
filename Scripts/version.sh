#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

source "$ROOT/Scripts/_lib.sh"

PROJECT=${PROJECT:-Mouth.xcodeproj}
SCHEME=${SCHEME:-Mouth}
CONFIGURATION=${CONFIGURATION:-Release}

require_cmd xcodebuild

TMPDIR="$(mktemp_dir /tmp/mouth-settings.XXXXXX)"
trap 'trash_if_exists "$TMPDIR"' EXIT

SETTINGS="$TMPDIR/build-settings.txt"
xcode_show_build_settings "$PROJECT" "$SCHEME" "$CONFIGURATION" >"$SETTINGS"

MARKETING_VERSION="$(extract_setting "$SETTINGS" MARKETING_VERSION)"
BUILD_NUMBER="$(extract_setting "$SETTINGS" CURRENT_PROJECT_VERSION)"
BUNDLE_ID="$(extract_setting "$SETTINGS" PRODUCT_BUNDLE_IDENTIFIER)"
TEAM_ID="$(extract_setting "$SETTINGS" DEVELOPMENT_TEAM)"
PRODUCT_NAME="$(extract_setting "$SETTINGS" PRODUCT_NAME)"

[[ -n "$MARKETING_VERSION" ]] || err "Could not extract MARKETING_VERSION from xcodebuild settings."
[[ -n "$BUILD_NUMBER" ]] || err "Could not extract CURRENT_PROJECT_VERSION from xcodebuild settings."

cat <<EOF
MARKETING_VERSION=$MARKETING_VERSION
BUILD_NUMBER=$BUILD_NUMBER
BUNDLE_ID=${BUNDLE_ID:-}
TEAM_ID=${TEAM_ID:-}
PRODUCT_NAME=${PRODUCT_NAME:-}
EOF

