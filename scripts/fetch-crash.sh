#!/usr/bin/env bash
# Read TestFlight crash feedback. Does not create or revoke certificates.
set -euo pipefail
export PYTHONUNBUFFERED=1

cd "$(dirname "$0")/.."

mask() {
  local value="${1:-}"
  local line
  [ -n "$value" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "::add-mask::${line}"
  done <<< "$value"
}

mask "${ASC_ISSUER_ID:-}"
mask "${ASC_KEY_ID:-}"
mask "${ASC_PRIVATE_KEY:-}"

if [ -z "${ASC_ISSUER_ID:-}" ] || [ -z "${ASC_KEY_ID:-}" ] || [ -z "${ASC_PRIVATE_KEY:-}" ]; then
  echo "ASC_ISSUER_ID, ASC_KEY_ID and ASC_PRIVATE_KEY must be available."
  exit 1
fi
if ! [[ "${ASC_KEY_ID}" =~ ^[A-Za-z0-9]+$ ]]; then
  echo "ASC_KEY_ID is not alphanumeric."
  exit 1
fi

ASC_DIR="$(mktemp -d "${RUNNER_TEMP:-/tmp}/asc.XXXXXX")"
chmod 700 "$ASC_DIR"
export ASC_DIR
export KEY_PATH="${ASC_DIR}/AuthKey_${ASC_KEY_ID}.p8"
export CRASH_DIR="${PWD}/crash-logs"
mkdir -p "$CRASH_DIR"

cleanup() {
  python3 scripts/asc_testflight.py scrub "$PWD/crash-fetch.log" || true
  rm -rf "$ASC_DIR"
}
trap cleanup EXIT

python3 scripts/asc_testflight.py crash-logs 2>&1 | tee "$PWD/crash-fetch.log"
