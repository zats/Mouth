#!/usr/bin/env bash
set -euo pipefail

err() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Missing required command: $1"
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || err "Missing required env var: $name"
}

require_clean_worktree() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || err "Not a git repo."
  # Allow untracked build products but require no staged/unstaged tracked changes.
  local status
  status="$(git status --porcelain)"
  if [[ -n "$status" ]]; then
    err "Worktree is dirty. Commit/stash changes before releasing.\n\n$status"
  fi
}

require_trash() {
  require_cmd trash
}

trash_if_exists() {
  local path="$1"
  if [[ -e "$path" ]]; then
    trash --stopOnError "$path" >/dev/null 2>&1 || true
  fi
}

mktemp_dir() {
  local template="${1:-/tmp/mouth.XXXXXX}"
  mktemp -d "$template"
}

run_logged() {
  # Usage: run_logged <logfile> <command...>
  local log="$1"; shift
  set +e
  "$@" >"$log" 2>&1
  local status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    echo "Command failed (exit $status): $*" >&2
    echo "Log: $log" >&2
    # Print a bounded set of failure markers from the *full* log.
    rg -n "(^|\\s)(error:|fatal error:|clang: error:|Swift\\.CompilerError|Ld .* failed|Command .* failed)" -S "$log" >&2 || true
    exit $status
  fi
  # Even successful builds can hide earlier errors in some setups; treat error markers as failure.
  local markers
  markers="$(rg -n "(^|\\s)(error:|fatal error:|clang: error:|Swift\\.CompilerError|Ld .* failed|Command .* failed)" -S "$log" || true)"
  if [[ -n "$markers" ]]; then
    echo "Command succeeded but error markers were found in log (unexpected): $*" >&2
    echo "Log: $log" >&2
    echo "$markers" >&2
    exit 1
  fi
}

xcode_show_build_settings() {
  local project="$1"
  local scheme="$2"
  local configuration="$3"
  xcodebuild -project "$project" -scheme "$scheme" -configuration "$configuration" \
    -destination 'generic/platform=macOS' \
    -showBuildSettings
}

extract_setting() {
  # Usage: extract_setting <settings_file> <SETTING_NAME>
  local file="$1"
  local name="$2"
  # Match the final assignment if it appears multiple times.
  awk -v k="$name" '
    $1 == k && $2 == "=" {
      v=$3
      for (i=4;i<=NF;i++) v=v" "$i
      last=v
    }
    END { print last }
  ' "$file"
}
