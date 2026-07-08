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
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --no-publish) PUBLISH=0 ;;
    --force) FORCE=1 ;;
  esac
done

# Repo root = parent of this script's directory.
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PROJECT="$ROOT/macos/$SCHEME.xcodeproj"
PLIST="$ROOT/macos/$SCHEME/Info.plist"
EXPORT_OPTS="$ROOT/macos/ExportOptions.plist"
BUILD="$ROOT/build/release"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
TAG="v$VERSION"
ZIP="$BUILD/$SCHEME-macOS-$TAG.zip"
DSYM_ZIP="$BUILD/$SCHEME-$TAG-dSYMs.zip"
APPCAST="$ROOT/docs/appcast.xml"

# Publishing guards only — `--no-publish` stays usable mid-development to
# test signing/notarization of work-in-progress.
if [[ "$PUBLISH" -eq 1 ]]; then
  echo "==> Preflight"
  # Never ship code that isn't committed and pushed — the release tag must
  # point at exactly the commit that produced the binary.
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: working tree is dirty — commit or stash before releasing." >&2
    exit 1
  fi
  git fetch -q origin
  if [[ "$(git rev-parse HEAD)" != "$(git rev-parse '@{upstream}' 2>/dev/null)" ]]; then
    echo "ERROR: HEAD is not pushed to its upstream — push before releasing." >&2
    exit 1
  fi
  # Refuse to silently clobber an already-published release (would break the
  # Homebrew cask's sha256 for everyone until the cask updates).
  if [[ "$FORCE" -ne 1 ]] && gh release view "$TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
    echo "ERROR: release $TAG already exists — bump CFBundleShortVersionString in Info.plist, or pass --force to overwrite." >&2
    exit 1
  fi
fi

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

echo "==> Archiving dSYMs (needed to symbolicate user crash reports)"
ditto -c -k --keepParent "$BUILD/$SCHEME.xcarchive/dSYMs" "$DSYM_ZIP"
echo "    -> $DSYM_ZIP"

if [[ "$PUBLISH" -eq 1 ]]; then
  if gh release view "$TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
    echo "==> Uploading assets to existing release $TAG (--force)"
    gh release upload "$TAG" "$ZIP" "$DSYM_ZIP" --repo "$REPO_SLUG" --clobber
  else
    echo "==> Creating release $TAG with assets"
    gh release create "$TAG" "$ZIP" "$DSYM_ZIP" --repo "$REPO_SLUG" \
      --target "$(git rev-parse HEAD)" \
      --title "MKV QuickPlay $TAG" --notes "See CHANGELOG.md for details." --latest
  fi
  echo "==> Published: https://github.com/$REPO_SLUG/releases/tag/$TAG"

  # Cask first: it must not be skippable by an appcast/signing failure below.
  echo "==> Updating Homebrew cask"
  "$ROOT/scripts/update-cask.sh" || echo "    (cask update skipped/failed — update tehshawn/homebrew-tap manually)"

  echo "==> Generating Sparkle appcast"
  # Newest DerivedData first; `|| true` because a missed glob would otherwise
  # abort the whole script under set -euo pipefail.
  SPARKLE_BIN="$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/$SCHEME-*/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null | head -1 || true)"
  # sign_update prints: sparkle:edSignature="…" length="…". Run it inside the
  # condition so a failure (locked keychain, missing key) degrades to the
  # warning below instead of killing the script mid-release.
  if [[ -n "$SPARKLE_BIN" && -x "$SPARKLE_BIN/sign_update" ]] \
     && SIGNATURE_ATTRS="$("$SPARKLE_BIN/sign_update" "$ZIP")"; then
    PUB_DATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
    DOWNLOAD_URL="https://github.com/$REPO_SLUG/releases/download/$TAG/$(basename "$ZIP")"
    cat > "$APPCAST" <<APPCAST_EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>MKV QuickPlay</title>
    <item>
      <title>MKV QuickPlay $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD_NUM</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO_SLUG/releases/tag/$TAG</sparkle:releaseNotesLink>
      <enclosure url="$DOWNLOAD_URL" $SIGNATURE_ATTRS type="application/octet-stream"/>
    </item>
  </channel>
</rss>
APPCAST_EOF
    git add "$APPCAST"
    git commit -qm "Appcast for $TAG"
    git push -q
    echo "    -> https://tehshawn.github.io/mkvquickplay/appcast.xml (live once Pages redeploys)"
  else
    echo "    WARNING: appcast not generated (Sparkle tools or EdDSA key unavailable)." >&2
    echo "    In-app updates won't see $TAG. Fix the tools/keychain and re-run: scripts/release.sh --force" >&2
  fi
else
  echo "==> --no-publish: skipped GitHub upload"
fi

echo "==> Done."
