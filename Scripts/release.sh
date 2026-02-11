#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

source "$ROOT/Scripts/_lib.sh"

PROJECT=${PROJECT:-Mouth.xcodeproj}
SCHEME=${SCHEME:-Mouth}
CONFIGURATION=${CONFIGURATION:-Release}

APP_NAME=${APP_NAME:-Mouth}
DRY_RUN=${DRY_RUN:-0}

require_trash
require_cmd git
require_cmd gh

ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
[[ -n "$ORIGIN_URL" ]] || err "No git remote named 'origin' is configured. Add it before releasing (git remote add origin <url>)."

require_clean_worktree

# Releases publish the appcast from a branch (defaults to "main").
FEED_BRANCH=${FEED_BRANCH:-main}
CURRENT_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
[[ -n "$CURRENT_BRANCH" ]] || err "Detached HEAD; checkout $FEED_BRANCH before releasing."
[[ "$CURRENT_BRANCH" == "$FEED_BRANCH" ]] || err "Releasing from '$CURRENT_BRANCH', but FEED_BRANCH is '$FEED_BRANCH'. Checkout '$FEED_BRANCH' (or set FEED_BRANCH)."

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
FEED_URL="https://raw.githubusercontent.com/${GITHUB_SLUG}/${FEED_BRANCH}/appcast.xml"
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

APPCAST_OUT="$ROOT/appcast.xml"
if [[ "$DRY_RUN" == "1" ]]; then
  DRY_DIR="$(mktemp_dir /tmp/mouth-release-dry.XXXXXX)"
  APPCAST_OUT="$DRY_DIR/appcast.xml"
fi

# Update appcast (normally committed to FEED_BRANCH and served from raw.githubusercontent.com).
SPARKLE_DOWNLOAD_URL_PREFIX="https://github.com/${GITHUB_SLUG}/releases/download/${TAG}/" \
  APPCAST_OUT="$APPCAST_OUT" \
  "$ROOT/Scripts/make_appcast.sh" "$ZIP" "$FEED_URL"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY_RUN=1: skipping appcast commit/tag/push/release"
  echo "Would commit appcast to: $ROOT/appcast.xml"
  echo "Generated appcast at: $APPCAST_OUT"
  echo "Would tag: $TAG"
  echo "Would push: origin $FEED_BRANCH and tag $TAG"
  echo "Would create GitHub release: $TAG"
  echo "Artifacts prepared in: ${RELEASE_DIR:-unknown}"
  echo "ZIP: $ZIP"
  echo "DMG: $DMG"
  if [[ -n "${DSYM_ZIP:-}" && -f "$DSYM_ZIP" ]]; then
    echo "DSYM_ZIP: $DSYM_ZIP"
  fi
  if [[ -n "${DRY_DIR:-}" ]]; then
    if [[ "${CLEANUP_RELEASE_DIR:-0}" == "1" ]]; then
      trash_if_exists "$DRY_DIR"
    else
      echo "Dry-run directory: $DRY_DIR"
    fi
  fi
  exit 0
fi

git add appcast.xml
git commit -m "Update appcast for ${TAG}"

# Tag + push before creating the release so the tag exists remotely.
if [[ "${FORCE_TAG:-0}" == "1" ]]; then
  git tag -f "$TAG"
else
  git tag "$TAG"
fi

git push origin "$FEED_BRANCH"
if [[ "${FORCE_TAG:-0}" == "1" ]]; then
  git push -f origin "$TAG"
else
  git push origin "$TAG"
fi

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
