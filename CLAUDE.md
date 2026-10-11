# MKV QuickPlay — project notes

macOS-only menu bar app for quick video preview via mpv. Source lives in `macos/`.
The app drives a single persistent mpv window over its JSON IPC socket
(`NSTemporaryDirectory()/mkvquickplay-<pid>-<n>.sock`, where `<pid>` is the
app's own pid and `<n>` a per-launch counter — the per-user temp dir under
`/var/folders/...`, not world-readable `/tmp`; the startup sweep deletes
leftover sockets except those whose `<pid>` is still running); navigation /
trash / undo keys are mpv `script-message`s delivered back as `client-message`
IPC events.

Runtime files: the mpv key-bindings file is rewritten before every player
launch at `~/Library/Application Support/MKVQuickPlay/input.conf` (never in
the temp dir — macOS purges `$TMPDIR` files not accessed for 3 days, which
once left sessions with no keys) and the same bindings are re-sent over IPC
with `keybind` on connect. mpv's stderr is forwarded to the system log with
an `[mpv]` prefix (bounded per launch).

## Building (dev)

Requires Xcode 26 or later (KeyboardShortcuts 3.x is a Swift 6.2 package;
its public API is MainActor-isolated, so call it only from main-thread
contexts — delegate methods or `@MainActor`-annotated methods).

```bash
cd macos
xcodebuild -project MKVQuickPlay.xcodeproj -scheme MKVQuickPlay -configuration Release build
```

## Releasing (REQUIRED process for every update)

Every public update must be **Developer ID-signed and notarized** so it downloads
and runs without Gatekeeper warnings. Do NOT publish a development-signed build.

Steps for each release:
1. Make the code changes.
2. Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in
   `macos/MKVQuickPlay/Info.plist`.
3. Add a section to `CHANGELOG.md`.
4. Commit (and push).
5. Run the release pipeline — it builds, signs with Developer ID, notarizes,
   staples, and creates/uploads the GitHub release asset:

   ```bash
   scripts/release.sh
   ```

The release tag/version comes from `Info.plist`, so step 2 drives everything.
IMPORTANT: bump `CFBundleVersion` too — Sparkle compares build numbers, so a
release without a build-number bump will never be offered as an update.

`release.sh` also:
- generates and pushes the Sparkle appcast (`docs/appcast.xml`, served via
  GitHub Pages at https://tehshawn.github.io/mkvquickplay/appcast.xml). The
  zip is signed with `sign_update` using the EdDSA private key stored in the
  login keychain (created once via Sparkle's `generate_keys`; public key lives
  in Info.plist as `SUPublicEDKey`). Sparkle's CLI tools resolve from the
  SwiftPM artifacts under DerivedData.
- runs `scripts/update-cask.sh`, which bumps the Homebrew cask (version +
  sha256, and ensures `auto_updates true`) in the `tehshawn/homebrew-tap` repo
  so `brew install --cask tehshawn/tap/mkvquickplay` stays current.

Dependencies (SwiftPM, declared in the Xcode project): `KeyboardShortcuts`
(global recordable hotkey) and `Sparkle` (auto-updates).

### One-time setup (already configured certs aside)

- Developer ID Application cert: "Developer ID Application: Shawn McEntyre (BVUHD2VQU7)".
- Notarization credentials stored as a keychain profile named `MKVQuickPlay-Notary`:

  ```bash
  xcrun notarytool store-credentials "MKVQuickPlay-Notary" \
    --apple-id "<apple-id-email>" --team-id "BVUHD2VQU7" \
    --password "<app-specific-password>"   # from appleid.apple.com
  ```

- `gh` CLI authenticated; remote is `tehshawn/mkvquickplay`.

Notarization and timestamped signing require network access to Apple's servers,
so `scripts/release.sh` must be run on the developer's Mac (not in a sandboxed
environment without network).

## Where things stand (updated 2026-10-11)

Latest release: **2.5.1 (build 13)**, published 2026-10-11 and verified end to
end (GitHub release + notarized zip, Homebrew cask, Sparkle feed on `main`).
A full audit against macOS 27.0.1 was done for this release; `CHANGELOG.md`
has the details. The headline items:

- **Root cause of "keys stop working after the app sits in the menu bar for
  days"**: the mpv key-bindings file was written once into `$TMPDIR`, which
  macOS purges after 3 days. Now rewritten before every mpv launch under
  Application Support and re-sent over IPC with `keybind`. mpv's stderr is
  forwarded to the system log (`[mpv]` prefix) so a recurrence leaves evidence.
- Finder's selection follows the playing file via an AppleScript `reveal` with
  no `activate`, so mpv never loses keyboard focus (the old activate-Finder-
  then-refocus-mpv dance is only a fallback; macOS 26/27 often decline it).
- KeyboardShortcuts 3.1.0 (the shortcut recorder was broken on macOS 26/27 in
  2.4.0) and Sparkle 2.10.0. KeyboardShortcuts 3.x is Swift 6.2 → Xcode 26+.

Still to confirm in real use: leave the app running untouched for 3+ days,
then preview a video — the arrow keys must still work. If not, Console.app →
search `MKVQuickPlay` or `[mpv]` and start from those lines.

Process lessons from the 2.5.1 release:
- Run `scripts/release.sh` from `main` (or fast-forward `main` to the release
  branch afterwards): the script commits `docs/appcast.xml` to whatever branch
  it runs on, and GitHub Pages only serves `main`.
- `macos/MKVQuickPlay/AppIcon.icon` must stay committed — `.gitignore` used to
  swallow the whole source folder (fixed; the rule is anchored to the root now).
- After bumping a SwiftPM dependency by hand, run
  `xcodebuild -resolvePackageDependencies -project MKVQuickPlay.xcodeproj -scheme MKVQuickPlay`
  in `macos/` and commit `Package.resolved` if it changed.
- Notarization returning HTTP 403 "required agreement is missing" means an
  Apple Developer agreement needs accepting on developer.apple.com (Account
  Holder); it can take a while to propagate. Test cheaply with
  `xcrun notarytool history --keychain-profile "MKVQuickPlay-Notary"`.

Small things noted during the audit but deliberately left alone (candidates
for a future release): the build warns that `AccentColor` is not in any asset
catalog (harmless; add one or drop the build setting); videos previewed from
the Desktop or a search/Recents/Tags window navigate alphabetically because
no Finder window exposes that view's sort; very large Finder selections
could use `selection as alias list` instead of the per-item loop.
