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

# Fail fast instead of hanging on a credential prompt mid-release.
export GIT_TERMINAL_PROMPT=0

git clone --depth 1 "https://github.com/$TAP_REPO.git" "$TMP/tap"
CASK="$TMP/tap/$CASK_PATH"

# The version currently published in the cask — i.e. what brew users have.
OLD_VERSION="$(sed -nE 's/^  version "(.*)"$/\1/p' "$CASK")"

sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/" "$CASK"
sed -i '' -E "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"

# The app self-updates via Sparkle from 2.4.0 on, and `brew upgrade` skips
# auto_updates casks. Only flag the cask once the version users are upgrading
# FROM already ships Sparkle — flagging it on the first Sparkle release would
# strand pre-2.4.0 brew installs (no in-app updater, no brew upgrade).
if ! grep -q "^  auto_updates true" "$CASK"; then
  if [[ -n "$OLD_VERSION" && "$(printf '%s\n' "2.4.0" "$OLD_VERSION" | sort -V | head -1)" == "2.4.0" ]]; then
    perl -0pi -e 's/\n  depends_on formula: "mpv"/\n  auto_updates true\n  depends_on formula: "mpv"/' "$CASK"
  fi
fi

# Positively verify the rewrite: if the cask was ever reformatted so the sed
# anchors stop matching, a silent no-op here would look like "already up to
# date" while shipping a stale version/sha to every brew user.
if ! grep -q "version \"$VERSION\"" "$CASK" || ! grep -q "sha256 \"$SHA\"" "$CASK"; then
  echo "ERROR: cask rewrite failed — sed patterns did not match $CASK_PATH. Update the cask manually." >&2
  exit 1
fi

if git -C "$TMP/tap" diff --quiet; then
  echo "Cask already up to date at $VERSION."
  exit 0
fi

git -C "$TMP/tap" commit -aqm "mkvquickplay $VERSION"
git -C "$TMP/tap" push -q
echo "Cask updated -> $VERSION ($SHA)"
