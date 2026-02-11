#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ZIP=${1:?"Usage: $0 Mouth-<ver>.zip [feed_url]"}
FEED_URL=${2:-""}
PRIVATE_KEY_FILE=${SPARKLE_PRIVATE_KEY_FILE:-}

if [[ -z "$PRIVATE_KEY_FILE" ]]; then
  echo "Set SPARKLE_PRIVATE_KEY_FILE to your Sparkle Ed25519 private key file." >&2
  exit 1
fi
if [[ ! -f "$PRIVATE_KEY_FILE" ]]; then
  echo "Sparkle key file not found: $PRIVATE_KEY_FILE" >&2
  exit 1
fi
if [[ ! -f "$ZIP" ]]; then
  echo "Zip not found: $ZIP" >&2
  exit 1
fi

ZIP_DIR="$(cd "$(dirname "$ZIP")" && pwd)"

DOWNLOAD_URL_PREFIX=${SPARKLE_DOWNLOAD_URL_PREFIX:-}
if [[ -z "$DOWNLOAD_URL_PREFIX" ]]; then
  echo "Set SPARKLE_DOWNLOAD_URL_PREFIX (e.g. https://github.com/<org>/<repo>/releases/download/v<ver>/)." >&2
  exit 1
fi

GEN_BIN="$(command -v generate_appcast || true)"
if [[ -z "$GEN_BIN" ]]; then
  # Best-effort lookup from Xcode DerivedData Sparkle artifact.
  GEN_BIN="$(/usr/bin/find "$HOME/Library/Developer/Xcode/DerivedData" -type f -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" -perm -111 2>/dev/null | head -n 1 || true)"
fi
if [[ -z "$GEN_BIN" ]]; then
  echo "generate_appcast not found. Install Sparkle tools, or ensure Xcode has resolved Sparkle package artifacts." >&2
  exit 1
fi

"$GEN_BIN" \
  --ed-key-file "$PRIVATE_KEY_FILE" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  ${FEED_URL:+--link "$FEED_URL"} \
  "$ZIP_DIR"

echo "Appcast generated (appcast.xml). Upload alongside $ZIP."

