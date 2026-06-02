#!/usr/bin/env bash
#
# release.sh — build, Developer ID-sign, notarize, staple, and publish
# MKV QuickPlay to GitHub Releases.
#
# Prerequisites (one-time):
#   1. A "Developer ID Application" certificate in your login keychain.
#   2. A stored notarytool credential profile named "$NOTARY_PROFILE":
#
#        xcrun notarytool store-credentials "MKVQuickPlay-Notary" \
#          --apple-id "YOUR_APPLE_ID_EMAIL" \
#          --team-id "BVUHD2VQU7" \
#          --password "APP_SPECIFIC_PASSWORD"   # from appleid.apple.com
#
#   3. The `gh` CLI authenticated (gh auth status).
#
# Usage:
#   scripts/release.sh             # build, notarize, and publish the release
#   scripts/release.sh --no-publish  # build + notarize only (no GitHub upload)
#
set -euo pipefail

TEAM_ID="BVUHD2VQU7"
NOTARY_PROFILE="MKVQuickPlay-Notary"
SCHEME="MKVQuickPlay"
REPO_SLUG="tehshawn/mkvquickplay"

PUBLISH=1
[[ "${1:-}" == "--no-publish" ]] && PUBLISH=0

# Repo root = parent of this script's directory.
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PROJECT="$ROOT/macos/$SCHEME.xcodeproj"
PLIST="$ROOT/macos/$SCHEME/Info.plist"
EXPORT_OPTS="$ROOT/macos/ExportOptions.plist"
BUILD="$ROOT/build/release"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
TAG="v$VERSION"
ZIP="$BUILD/$SCHEME-macOS-$TAG.zip"

echo "==> Releasing $SCHEME $TAG"
rm -rf "$BUILD"; mkdir -p "$BUILD"

echo "==> Archiving (Release)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -archivePath "$BUILD/$SCHEME.xcarchive" \
  archive

echo "==> Exporting Developer ID-signed app"
xcodebuild -exportArchive \
  -archivePath "$BUILD/$SCHEME.xcarchive" \
  -exportPath "$BUILD/export" \
  -exportOptionsPlist "$EXPORT_OPTS"

APP="$BUILD/export/$SCHEME.app"

echo "==> Zipping for notarization"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple notary service (this can take a few minutes)"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP"

echo "==> Verifying"
codesign --verify --strict --deep -vvv "$APP"
spctl -a -vvv -t exec "$APP"

echo "==> Re-zipping stapled app for distribution"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "    -> $ZIP"

if [[ "$PUBLISH" -eq 1 ]]; then
  if gh release view "$TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
    echo "==> Uploading asset to existing release $TAG"
    gh release upload "$TAG" "$ZIP" --repo "$REPO_SLUG" --clobber
  else
    echo "==> Creating release $TAG with asset"
    gh release create "$TAG" "$ZIP" --repo "$REPO_SLUG" \
      --title "MKV QuickPlay $TAG" --notes "See CHANGELOG.md for details." --latest
  fi
  echo "==> Published: https://github.com/$REPO_SLUG/releases/tag/$TAG"
else
  echo "==> --no-publish: skipped GitHub upload"
fi

echo "==> Done."
