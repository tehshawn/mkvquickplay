#!/usr/bin/env bash
#
# update-cask.sh — bump the Homebrew cask in tehshawn/homebrew-tap to match the
# current version (from Info.plist) and the freshly built release zip's SHA-256.
# Called automatically by release.sh; can also be run on its own after a release.
#
set -euo pipefail

TAP_REPO="tehshawn/homebrew-tap"
CASK_PATH="Casks/mkvquickplay.rb"

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PLIST="$ROOT/macos/MKVQuickPlay/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
ZIP="$ROOT/build/release/MKVQuickPlay-macOS-v$VERSION.zip"

if [[ ! -f "$ZIP" ]]; then
  echo "Release zip not found ($ZIP). Run scripts/release.sh first." >&2
  exit 1
fi
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git clone --depth 1 "https://github.com/$TAP_REPO.git" "$TMP/tap"
CASK="$TMP/tap/$CASK_PATH"

sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/" "$CASK"
sed -i '' -E "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"

if git -C "$TMP/tap" diff --quiet; then
  echo "Cask already up to date at $VERSION."
  exit 0
fi

git -C "$TMP/tap" commit -aqm "mkvquickplay $VERSION"
git -C "$TMP/tap" push -q
echo "Cask updated -> $VERSION ($SHA)"
