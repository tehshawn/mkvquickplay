#!/usr/bin/env bash
#
# update-appcast.sh — sign the built release zip and publish the Sparkle
# appcast (docs/appcast.xml, served via GitHub Pages). Release notes are
# extracted from the CHANGELOG.md section for the current version and
# embedded as HTML so the update window shows clean native-looking text
# (not a shrunken web page).
#
# Called by release.sh after publishing; can be run standalone as long as
# build/release/<zip> from the release build still exists.
#
set -euo pipefail

SCHEME="MKVQuickPlay"
REPO_SLUG="tehshawn/mkvquickplay"

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PLIST="$ROOT/macos/$SCHEME/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
TAG="v$VERSION"
ZIP="$ROOT/build/release/$SCHEME-macOS-$TAG.zip"
APPCAST="$ROOT/docs/appcast.xml"

if [[ ! -f "$ZIP" ]]; then
  echo "ERROR: $ZIP not found — run scripts/release.sh first." >&2
  exit 1
fi

# Newest DerivedData first; `|| true` so a missed glob doesn't abort under set -e.
SPARKLE_BIN="$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/$SCHEME-*/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null | head -1 || true)"
if [[ -z "$SPARKLE_BIN" || ! -x "$SPARKLE_BIN/sign_update" ]]; then
  echo "ERROR: Sparkle tools not found under DerivedData — run xcodebuild -resolvePackageDependencies." >&2
  exit 1
fi

# sign_update prints: sparkle:edSignature="…" length="…"
SIGNATURE_ATTRS="$("$SPARKLE_BIN/sign_update" "$ZIP")"
PUB_DATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
DOWNLOAD_URL="https://github.com/$REPO_SLUG/releases/download/$TAG/$(basename "$ZIP")"

# Extract this version's CHANGELOG section and convert the simple markdown
# (### headings, - bullets with wrapped lines, **bold**, `code`) to HTML.
RELEASE_NOTES_HTML="$(awk -v ver="$VERSION" '
  $0 ~ "^## \\[" ver "\\]" { insec = 1; next }
  insec && /^## \[/ { insec = 0 }
  insec { print }
' "$ROOT/CHANGELOG.md" | awk '
  function inline(s,   inner) {
    gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s)
    while (match(s, /\*\*[^*]+\*\*/)) {
      inner = substr(s, RSTART + 2, RLENGTH - 4)
      s = substr(s, 1, RSTART - 1) "<b>" inner "</b>" substr(s, RSTART + RLENGTH)
    }
    while (match(s, /`[^`]+`/)) {
      inner = substr(s, RSTART + 1, RLENGTH - 2)
      s = substr(s, 1, RSTART - 1) "<code>" inner "</code>" substr(s, RSTART + RLENGTH)
    }
    return s
  }
  function flushli() { if (li != "") { print "<li>" li "</li>"; li = "" } }
  /^### / { flushli(); if (inlist) { print "</ul>"; inlist = 0 } print "<h3>" inline(substr($0, 5)) "</h3>"; next }
  /^- /   { flushli(); if (!inlist) { print "<ul>"; inlist = 1 } li = inline(substr($0, 3)); next }
  /^  /   { if (li != "") { li = li " " inline(substr($0, 3)); next } }
  /^$/    { next }
  { flushli(); if (inlist) { print "</ul>"; inlist = 0 } print "<p>" inline($0) "</p>" }
  END { flushli(); if (inlist) print "</ul>" }
')"

if [[ -z "$RELEASE_NOTES_HTML" ]]; then
  RELEASE_NOTES_HTML="<p>See the <a href=\"https://github.com/$REPO_SLUG/releases/tag/$TAG\">release page</a> for details.</p>"
fi

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
      <description><![CDATA[
        <h2>MKV QuickPlay $VERSION</h2>
        $RELEASE_NOTES_HTML
        <p><a href="https://github.com/$REPO_SLUG/releases/tag/$TAG">Full release on GitHub</a></p>
      ]]></description>
      <enclosure url="$DOWNLOAD_URL" $SIGNATURE_ATTRS type="application/octet-stream"/>
    </item>
  </channel>
</rss>
APPCAST_EOF

# Sanity: the appcast must be valid XML before we publish it.
xmllint --noout "$APPCAST"

git add "$APPCAST"
if git diff --cached --quiet; then
  echo "Appcast unchanged."
else
  git commit -qm "Appcast for $TAG"
  git push -q
  echo "Appcast published -> https://tehshawn.github.io/mkvquickplay/appcast.xml"
fi
