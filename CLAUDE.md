# MKV QuickPlay — project notes

macOS-only menu bar app for quick video preview via mpv. Source lives in `macos/`.
The app drives a single persistent mpv window over its JSON IPC socket
(`/tmp/mkvquickplay.sock`); navigation / trash / undo keys are mpv
`script-message`s delivered back as `client-message` IPC events.

## Building (dev)

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
`release.sh` also runs `scripts/update-cask.sh`, which bumps the Homebrew cask
(version + sha256) in the `tehshawn/homebrew-tap` repo so
`brew install --cask tehshawn/tap/mkvquickplay` stays current.

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
