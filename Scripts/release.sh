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
REQUEST_CLEANUP_RELEASE_DIR=${CLEANUP_RELEASE_DIR:-0}
VERSION_BUMP=${VERSION_BUMP:-minor}
DRY_RUN_APPLY_VERSION_BUMP=${DRY_RUN_APPLY_VERSION_BUMP:-0}
RELEASE_MARKETING_VERSION=${RELEASE_MARKETING_VERSION:-}
RELEASE_BUILD_NUMBER=${RELEASE_BUILD_NUMBER:-}

require_trash
require_cmd git
require_cmd gh
require_cmd xcrun

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

bump_semver() {
  local version="$1"
  local part="$2"

  if [[ "$part" == "none" ]]; then
    printf "%s" "$version"
    return
  fi

  if [[ ! "$version" =~ ^([0-9]+)(\.([0-9]+))?(\.([0-9]+))?$ ]]; then
    err "Cannot ${part}-bump MARKETING_VERSION '$version'. Set RELEASE_MARKETING_VERSION explicitly."
  fi

  local major="${BASH_REMATCH[1]}"
  local minor="${BASH_REMATCH[3]:-0}"
  local patch="${BASH_REMATCH[5]:-0}"

  case "$part" in
    patch)
      patch=$((patch + 1))
      ;;
    minor)
      minor=$((minor + 1))
      patch=0
      ;;
    major)
      major=$((major + 1))
      minor=0
      patch=0
      ;;
    *)
      err "Unsupported VERSION_BUMP='$part'. Use one of: none, patch, minor, major."
      ;;
  esac

  printf "%d.%d.%d" "$major" "$minor" "$patch"
}

SETTINGS_TMP_DIR="$(mktemp_dir /tmp/mouth-release-settings.XXXXXX)"
cleanup_settings_dir() {
  trash_if_exists "$SETTINGS_TMP_DIR"
}
trap cleanup_settings_dir EXIT

CURRENT_MARKETING_VERSION="$(xcrun agvtool what-marketing-version -terse1 2>/dev/null | tr -d '\r' | tail -n 1 | tr -d '[:space:]')"
CURRENT_BUILD_NUMBER="$(xcrun agvtool what-version -terse 2>/dev/null | tr -d '\r' | tail -n 1 | tr -d '[:space:]')"
if [[ -z "$CURRENT_MARKETING_VERSION" || -z "$CURRENT_BUILD_NUMBER" ]]; then
  CURRENT_SETTINGS="$SETTINGS_TMP_DIR/current-build-settings.txt"
  xcode_show_build_settings "$PROJECT" "$SCHEME" "$CONFIGURATION" >"$CURRENT_SETTINGS"
  [[ -n "$CURRENT_MARKETING_VERSION" ]] || CURRENT_MARKETING_VERSION="$(extract_setting "$CURRENT_SETTINGS" MARKETING_VERSION)"
  [[ -n "$CURRENT_BUILD_NUMBER" ]] || CURRENT_BUILD_NUMBER="$(extract_setting "$CURRENT_SETTINGS" CURRENT_PROJECT_VERSION)"
fi
[[ -n "$CURRENT_MARKETING_VERSION" ]] || err "Could not extract MARKETING_VERSION before bump."
[[ -n "$CURRENT_BUILD_NUMBER" ]] || err "Could not extract CURRENT_PROJECT_VERSION before bump."

TARGET_MARKETING_VERSION="$CURRENT_MARKETING_VERSION"
if [[ -n "$RELEASE_MARKETING_VERSION" ]]; then
  TARGET_MARKETING_VERSION="$RELEASE_MARKETING_VERSION"
else
  TARGET_MARKETING_VERSION="$(bump_semver "$CURRENT_MARKETING_VERSION" "$VERSION_BUMP")"
fi

if [[ "$DRY_RUN" == "1" && "$DRY_RUN_APPLY_VERSION_BUMP" != "1" ]]; then
  echo "DRY_RUN=1: skipping version bump"
  if [[ "$TARGET_MARKETING_VERSION" != "$CURRENT_MARKETING_VERSION" ]]; then
    echo "Would set MARKETING_VERSION: $CURRENT_MARKETING_VERSION -> $TARGET_MARKETING_VERSION"
  fi
  if [[ -n "$RELEASE_BUILD_NUMBER" ]]; then
    echo "Would set CURRENT_PROJECT_VERSION: $CURRENT_BUILD_NUMBER -> $RELEASE_BUILD_NUMBER"
  else
    echo "Would increment CURRENT_PROJECT_VERSION from: $CURRENT_BUILD_NUMBER"
  fi
else
  if [[ "$TARGET_MARKETING_VERSION" != "$CURRENT_MARKETING_VERSION" ]]; then
    xcrun agvtool new-marketing-version "$TARGET_MARKETING_VERSION" >/dev/null
  fi

  if [[ -n "$RELEASE_BUILD_NUMBER" ]]; then
    xcrun agvtool new-version -all "$RELEASE_BUILD_NUMBER" >/dev/null
  else
    xcrun agvtool next-version -all >/dev/null
  fi

  UPDATED_MARKETING_VERSION="$(xcrun agvtool what-marketing-version -terse1 2>/dev/null | tr -d '\r' | tail -n 1 | tr -d '[:space:]')"
  UPDATED_BUILD_NUMBER="$(xcrun agvtool what-version -terse 2>/dev/null | tr -d '\r' | tail -n 1 | tr -d '[:space:]')"
  if [[ -z "$UPDATED_MARKETING_VERSION" || -z "$UPDATED_BUILD_NUMBER" ]]; then
    UPDATED_SETTINGS="$SETTINGS_TMP_DIR/updated-build-settings.txt"
    xcode_show_build_settings "$PROJECT" "$SCHEME" "$CONFIGURATION" >"$UPDATED_SETTINGS"
    [[ -n "$UPDATED_MARKETING_VERSION" ]] || UPDATED_MARKETING_VERSION="$(extract_setting "$UPDATED_SETTINGS" MARKETING_VERSION)"
    [[ -n "$UPDATED_BUILD_NUMBER" ]] || UPDATED_BUILD_NUMBER="$(extract_setting "$UPDATED_SETTINGS" CURRENT_PROJECT_VERSION)"
  fi
  [[ -n "$UPDATED_MARKETING_VERSION" ]] || err "Could not extract updated MARKETING_VERSION."
  [[ -n "$UPDATED_BUILD_NUMBER" ]] || err "Could not extract updated CURRENT_PROJECT_VERSION."

  git add -A
  git commit -m "Bump version to ${UPDATED_MARKETING_VERSION} (${UPDATED_BUILD_NUMBER})"
fi

# Build + notarize + package (zip + dmg + dsym).
FEED_URL="https://raw.githubusercontent.com/${GITHUB_SLUG}/${FEED_BRANCH}/appcast.xml"
MOUTH_SPARKLE_FEED_URL="$FEED_URL" CLEANUP_RELEASE_DIR=0 "$ROOT/Scripts/sign-and-notarize.sh"

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
  if [[ "$REQUEST_CLEANUP_RELEASE_DIR" == "1" && -n "${RELEASE_DIR:-}" ]]; then
    trash_if_exists "$RELEASE_DIR"
  fi
  if [[ -n "${DRY_DIR:-}" ]]; then
    if [[ "$REQUEST_CLEANUP_RELEASE_DIR" == "1" ]]; then
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

if [[ "$REQUEST_CLEANUP_RELEASE_DIR" == "1" && -n "${RELEASE_DIR:-}" ]]; then
  trash_if_exists "$RELEASE_DIR"
fi
