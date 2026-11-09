#!/usr/bin/env bash
# Archives FriendCal, uploads it to App Store Connect (TestFlight), and bumps the build number.
#
# Usage: scripts/testflight.sh [--no-bump]
#
# Needs: Xcode signed in to the paid team, app/Config/Local.xcconfig with DEVELOPMENT_TEAM,
# fonts (scripts/fetch-fonts.sh), and an App Store Connect app record for com.friendcal.app.
# Every upload needs a build number higher than any earlier one for the same MARKETING_VERSION,
# so the script increments CURRENT_PROJECT_VERSION in app/project.yml first. Commit that bump.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/app"
OUT="$HOME/Library/Caches/friendcal-archive"

cd "$APP"

if [ ! -f Config/Local.xcconfig ]; then
  echo "error: app/Config/Local.xcconfig is missing (set DEVELOPMENT_TEAM, see Local.xcconfig.example)" >&2
  exit 1
fi

if [ "${1:-}" != "--no-bump" ]; then
  current="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\([0-9]*\)".*/\1/p' project.yml)"
  [ -n "$current" ] || { echo "error: CURRENT_PROJECT_VERSION not found in project.yml" >&2; exit 1; }
  next=$((current + 1))
  sed -i '' "s/^\( *CURRENT_PROJECT_VERSION: *\)\"$current\"/\1\"$next\"/" project.yml
  echo "build number $current -> $next"
  xcodegen generate
fi

rm -rf "$OUT"
xcodebuild archive -project FriendCal.xcodeproj -scheme FriendCal \
  -destination 'generic/platform=iOS' -archivePath "$OUT/FriendCal.xcarchive" \
  -allowProvisioningUpdates | tail -3

xcodebuild -exportArchive -archivePath "$OUT/FriendCal.xcarchive" \
  -exportOptionsPlist Config/ExportOptions.plist -exportPath "$OUT/export" \
  -allowProvisioningUpdates | grep -E "Upload succeeded|EXPORT|error" || true

echo "Processing takes 5-15 min; Apple emails when the build is ready in TestFlight."
