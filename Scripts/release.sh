#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

source "$ROOT/Scripts/_lib.sh"

PROJECT=${PROJECT:-Mouth.xcodeproj}
SCHEME=${SCHEME:-Mouth}
CONFIGURATION=${CONFIGURATION:-Release}

APP_NAME=${APP_NAME:-Mouth}

require_trash
require_cmd git
require_cmd gh

ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
[[ -n "$ORIGIN_URL" ]] || err "No git remote named 'origin' is configured. Add it before releasing (git remote add origin <url>)."

require_clean_worktree

# Resolve GitHub slug from origin URL (supports SSH and HTTPS).
resolve_github_slug() {
  local url="$1"
  local slug=""
  if [[ "$url" =~ ^git@github.com:([^/]+/[^/]+)(\\.git)?$ ]]; then
    slug="${BASH_REMATCH[1]}"
  elif [[ "$url" =~ ^https://github.com/([^/]+/[^/]+)(\\.git)?$ ]]; then
    slug="${BASH_REMATCH[1]}"
  fi
  slug="${slug%.git}"
  [[ -n "$slug" ]] || err "Unsupported origin URL for GitHub releases: $url"
  printf "%s" "$slug"
}

GITHUB_SLUG="$(resolve_github_slug "$ORIGIN_URL")"

# Build + notarize + package (zip + dmg + dsym).
FEED_URL="https://raw.githubusercontent.com/${GITHUB_SLUG}/main/appcast.xml"
MOUTH_SPARKLE_FEED_URL="$FEED_URL" "$ROOT/Scripts/sign-and-notarize.sh"

# Load outputs.
OUT_ENV="/tmp/mouth-last-release-outputs.env"
[[ -f "$OUT_ENV" ]] || err "Missing $OUT_ENV (expected sign-and-notarize.sh to write it)."

set -a
source "$OUT_ENV"
set +a

[[ -n "${TAG:-}" ]] || err "Missing TAG in $OUT_ENV"
[[ -n "${ZIP:-}" && -f "$ZIP" ]] || err "Missing ZIP in $OUT_ENV"
[[ -n "${DMG:-}" && -f "$DMG" ]] || err "Missing DMG in $OUT_ENV"

TITLE="${APP_NAME} ${MARKETING_VERSION}"

# Update appcast.xml (served from main via raw.githubusercontent.com).
SPARKLE_DOWNLOAD_URL_PREFIX="https://github.com/${GITHUB_SLUG}/releases/download/${TAG}/" \
  "$ROOT/Scripts/make_appcast.sh" "$ZIP" "$FEED_URL"

git add appcast.xml
git commit -m "Update appcast for ${TAG}"

# Tag + push before creating the release so the tag exists remotely.
git tag -f "$TAG"
git push origin HEAD
git push -f origin "$TAG"

ASSETS=("$ZIP" "$DMG")
if [[ -n "${DSYM_ZIP:-}" && -f "$DSYM_ZIP" ]]; then
  ASSETS+=("$DSYM_ZIP")
fi

gh release create "$TAG" "${ASSETS[@]}" \
  --title "$TITLE" \
  --generate-notes

echo "GitHub release created for $TAG"
echo "Assets uploaded from: ${RELEASE_DIR:-unknown}"

if [[ "${CLEANUP_RELEASE_DIR:-0}" == "1" && -n "${RELEASE_DIR:-}" ]]; then
  trash_if_exists "$RELEASE_DIR"
fi
