#!/usr/bin/env bash
# Archive Vela with automatic App Store Connect signing and upload to TestFlight.
# Do not enable xtrace: the process environment holds the API key.
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
mask "${DEVELOPMENT_TEAM:-}"

LOG="${PWD}/testflight.log"
: > "$LOG"

if [ -z "${ASC_ISSUER_ID:-}" ] || [ -z "${ASC_KEY_ID:-}" ] || [ -z "${ASC_PRIVATE_KEY:-}" ]; then
  echo "ASC_ISSUER_ID, ASC_KEY_ID and ASC_PRIVATE_KEY must be available to this job."
  exit 1
fi
if ! [[ "${ASC_KEY_ID}" =~ ^[A-Za-z0-9]+$ ]]; then
  echo "ASC_KEY_ID is not alphanumeric."
  exit 1
fi

ASC_DIR="$(mktemp -d "${RUNNER_TEMP:-/tmp}/asc.XXXXXX")"
chmod 700 "$ASC_DIR"
export ASC_DIR
# Xcode requires this filename. The id is masked and scrubbed from logs.
export KEY_PATH="${ASC_DIR}/AuthKey_${ASC_KEY_ID}.p8"

cleanup() {
  python3 scripts/asc_testflight.py scrub "$LOG" || true
  rm -rf "$ASC_DIR"
}
trap cleanup EXIT

run_logged() {
  "$@" 2>&1 | tee -a "$LOG"
}

BUILD="${GITHUB_RUN_NUMBER:?github.run_number is missing}"
echo "TestFlight upload for de.barczewski.vela, CFBundleVersion ${BUILD}" | tee -a "$LOG"

run_logged python3 scripts/asc_testflight.py prepare
TEAM="$(tr -d '[:space:]' < "${ASC_DIR}/team_id")"
if ! [[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Team ID was not a 10-character Apple Team ID."
  exit 1
fi

ARCHIVE="${ASC_DIR}/Vela.xcarchive"
echo "Archiving (automatic cloud signing)" | tee -a "$LOG"
run_logged xcodebuild \
  -project Vela.xcodeproj \
  -scheme Vela \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "${ASC_DIR}/DerivedData" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  PRODUCT_BUNDLE_IDENTIFIER="de.barczewski.vela" \
  DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  archive

PLIST="${ARCHIVE}/Products/Applications/Vela.app/Info.plist"
test -f "$PLIST"
GOT_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
GOT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
GOT_ENC="$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$PLIST")"
echo "Archived ${GOT_ID} ${GOT_BUILD}, ITSAppUsesNonExemptEncryption=${GOT_ENC}" | tee -a "$LOG"
if [ "$GOT_ID" != "de.barczewski.vela" ] || [ "$GOT_BUILD" != "$BUILD" ] || [ "$GOT_ENC" != "false" ]; then
  echo "Archive Info.plist does not match the TestFlight settings."
  exit 1
fi

echo "Uploading archive to App Store Connect" | tee -a "$LOG"
set +e
run_logged xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "${ASC_DIR}/export" \
  -exportOptionsPlist "${ASC_DIR}/ExportOptions.plist" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
EXPORT_STATUS=$?
set -e

if [ "$EXPORT_STATUS" -ne 0 ]; then
  if grep -E -q -i 'No suitable application records|Unable to find an application|could not find an app|No application records|application record' "$LOG"; then
    python3 scripts/asc_testflight.py owner-app || true
  fi
  if grep -E -q -i 'license agreement|Program License|must agree|paid application agreement' "$LOG"; then
    echo "OWNER ACTION: Der Apple-Developer-Vertrag muss unter developer.apple.com/account oder in App Store Connect akzeptiert werden."
  fi
  exit "$EXPORT_STATUS"
fi

run_logged python3 scripts/asc_testflight.py poll
