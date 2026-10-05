#!/usr/bin/env bash
# Archives the Kaiku iPhone app and uploads it to App Store Connect (TestFlight).
# Signing is automatic. For unattended runs set ASC_API_KEY_PATH, ASC_API_KEY_ID and ASC_API_ISSUER_ID.
# Set SKIP_UPLOAD=1 to only archive.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
ARCHIVE="$BUILD/Kaiku.xcarchive"

[ -d "$ROOT/vendor/whisper.xcframework" ] || "$ROOT/scripts/build-whisper-xcframework.sh"

xcodegen --spec "$ROOT/project.yml"

auth=()
if [ -n "${ASC_API_KEY_PATH:-}" ] && [ -n "${ASC_API_KEY_ID:-}" ] && [ -n "${ASC_API_ISSUER_ID:-}" ]; then
    auth=(-authenticationKeyPath "$ASC_API_KEY_PATH" -authenticationKeyID "$ASC_API_KEY_ID" -authenticationKeyIssuerID "$ASC_API_ISSUER_ID")
fi

rm -rf "$ARCHIVE"
xcodebuild -project "$ROOT/Kaiku.xcodeproj" -scheme Kaiku -destination generic/platform=iOS \
    -archivePath "$ARCHIVE" CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)" \
    -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} archive

[ "${SKIP_UPLOAD:-}" = 1 ] && { echo "Archived to $ARCHIVE"; exit 0; }

xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$ROOT/ExportOptions.plist" \
    -exportPath "$BUILD/export" -allowProvisioningUpdates ${auth[@]+"${auth[@]}"}
