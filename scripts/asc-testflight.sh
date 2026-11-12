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
  if [ -n "${KEYCHAIN_PATH:-}" ]; then
    security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
  fi
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

install_signing_assets() {
  local pass decoded uuid
  pass="$(openssl rand -hex 18)"
  KEYCHAIN_PATH="${ASC_DIR}/signing.keychain-db"
  security create-keychain -p "$pass" "$KEYCHAIN_PATH"
  security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
  security unlock-keychain -p "$pass" "$KEYCHAIN_PATH"
  security list-keychains -d user -s "$KEYCHAIN_PATH" "$HOME/Library/Keychains/login.keychain-db"
  security default-keychain -s "$KEYCHAIN_PATH"
  if ! openssl pkcs12 -export -legacy \
      -inkey "${ASC_DIR}/dist.key" -in "${ASC_DIR}/cert.pem" \
      -out "${ASC_DIR}/dist.p12" -passout pass:"$pass"; then
    openssl pkcs12 -export \
      -inkey "${ASC_DIR}/dist.key" -in "${ASC_DIR}/cert.pem" \
      -out "${ASC_DIR}/dist.p12" -passout pass:"$pass"
  fi
  security import "${ASC_DIR}/dist.p12" -k "$KEYCHAIN_PATH" -P "$pass" -A -t cert -t priv -f pkcs12
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pass" "$KEYCHAIN_PATH" >/dev/null
  decoded="${ASC_DIR}/profile.plist"
  security cms -D -i "${ASC_DIR}/vela.mobileprovision" > "$decoded"
  uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$decoded")"
  mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
  cp "${ASC_DIR}/vela.mobileprovision" "$HOME/Library/MobileDevice/Provisioning Profiles/${uuid}.mobileprovision"
  echo "Signing identity:"
  security find-identity -v -p codesigning "$KEYCHAIN_PATH" || true
}

install_signing_assets > >(tee -a "$LOG") 2>&1

ARCHIVE="${ASC_DIR}/Vela.xcarchive"
echo "Archiving with the App Store profile" | tee -a "$LOG"
run_logged xcodebuild \
  -project Vela.xcodeproj \
  -scheme Vela \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "${ASC_DIR}/DerivedData" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  CURRENT_PROJECT_VERSION="$BUILD" \
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
