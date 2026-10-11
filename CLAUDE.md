# MKV QuickPlay — project notes

macOS-only menu bar app (LSUIElement, AppKit/Swift) for QuickLook-style video
preview and folder culling from Finder. Source lives in `macos/`.

It launches an external **mpv** (Homebrew/MacPorts — located by probing a fixed
list in `findMPV()`, no PATH lookup) and drives **one persistent player window**
over mpv's JSON IPC socket. Navigating loads the next file into the same window
(`loadfile … replace`) rather than relaunching. Entry points: an **NSServices**
item (Finder ▸ Services, zero permissions) and a **global hotkey**
(KeyboardShortcuts, default ⇧⌘V, user-recordable) which reads the Finder
selection and therefore needs the **Automation** permission.

Deployment target is **macOS 13.0**; `#available(macOS 14, *)` fallbacks exist
throughout for that reason. Build requires **Xcode 26+**.

## Invariants — break these and the app misbehaves subtly

### IPC / player (`MPVLauncher.swift`)
- **`generation` is the one invalidation token.** Bumped by both
  `connectSocket()` and `teardownSocket()`, guarded by `stateLock`. *Every*
  async IPC actor must capture its generation and pass it back
  (`attemptConnect(generation:)`, `startReading(fd:generation:)`,
  `teardownSocket(ifGeneration:)`, `writeNow(_:generation:)`). Omitting it lets
  a dying player's EOF or late write tear down the **successor** session's
  channel — the session silently loses all keys.
- **Threading contract (convention only, not enforced by types):**
  - *ioQueue owns*: `socketFD`, `readSource`, `readBuffer`, `pendingCommands`,
    `pendingVolume`, `pendingMute`, `prefsFlushScheduled`
  - *main thread owns*: `mpvProcess`, `currentSocketPath`, `launchCounter`,
    `sessionActivity`
  - *`stateLock` guards*: `generation`, `connected`, `connecting`, `launchConnect`
  - **ioQueue must never block on main.** `flushPrefsForTermination()` does
    `ioQueue.sync` from `applicationWillTerminate`; any main-sync from ioQueue
    deadlocks termination. All IPC callbacks hop with `.async`.
- **The `keyBindings` table is the entire keyboard surface** — mpv runs with
  `--no-input-default-bindings`, so *every* key (including SPACE/←/→/m/f/ESC/q)
  comes from that table. It is installed **twice**: written to
  `~/Library/Application Support/MKVQuickPlay/input.conf` before every launch
  (temp dir only as a last-resort fallback) **and** re-sent as `keybind`
  commands on connect. Five keys emit `script-message`s whose names must stay in
  sync with the `client-message` switch in `processBuffer()`:
  `mkvqp-next` (↓), `mkvqp-prev` (↑), `mkvqp-trash` (BS/DEL),
  `mkvqp-undo` (⌘Z), `mkvqp-tag` (P). Adding a script-message without a
  `processBuffer` case silently drops it. Client-messages are
  **generation-checked again at delivery time on main** — a keypress event
  queued behind a main-thread stall must not act on a successor session's
  file (a late trash would delete the wrong video).
  *History:* the file used to be written once into `$TMPDIR`, which macOS purges
  of files untouched for 3 days — after a few days in the menu bar every player
  opened with **no keys at all**. The IPC re-install is the real safety net.
- **Commands issued before the channel opens are queued** (bounded FIFO of 16,
  oldest evicted) and flushed inline after the keybind/`observe_property` setup
  writes, in one ioQueue block. This is why re-invoking during a cold start no
  longer kills and relaunches the player.
- `play()` uses `canAcceptCommands` (one lock acquisition, not two property
  reads); `load()` deliberately uses the stricter `isPlaying && isConnected` so
  navigation can never resurrect a player the user just closed.
- Self-heal: `reconnectIfPlayerAlive()` reopens the channel if it drops while
  mpv runs; `attemptConnect` patrols ~2 min (60×50ms then 240×500ms).
- SIGPIPE is suppressed twice on purpose (`signal(SIGPIPE, SIG_IGN)` **and**
  `SO_NOSIGPIPE` per fd) — a write to a peer-closed socket would otherwise kill
  the whole app when mpv exits mid-command.
- Load-bearing mpv args: `--force-window=immediate` (IPC server must exist
  before decode), `--keep-open=yes` (EOF must not quit mpv), `--autofit-larger=90%x90%`
  + `--auto-window-resize=yes` (native size), `--msg-level=all=warn` with stderr
  forwarded to the system log as `[mpv]` (bounded per launch — mpv blocks on a
  full stderr pipe, and this being `/dev/null` is how the keyless bug hid).
- Volume/mute: `observe_property` → 0.5s coalesced flush → UserDefaults
  `mkvqp.volume` / `mkvqp.mute` → restored as launch args.

### Finder integration (`FinderSelectionManager.swift`, `AppDelegate.swift`)
- **Always shell out to `/usr/bin/osascript`; never `NSAppleScript`** (it is
  main-thread bound and blocks unboundedly on the TCC consent prompt). Three
  safety mechanics are load-bearing: in-script `with timeout` (3 s for
  sort/reveal, **15 s for the selection fetch**); **both pipes drained before
  `waitUntilExit()`** (a 64 KB buffer fills on a large selection and
  deadlocks); a 30 s SIGTERM → +2 s SIGKILL watchdog whose work item
  **weak-captures the Process** (a strong capture parked every exited child's
  pipe fds for the full 30 s — fd exhaustion during long culling runs).
- The selection fetch is **one `selection as alias list` Apple Event** with
  local alias→path coercion, paths joined by ASCII RS (0x1E). Reverting to a
  per-item `get selection` loop times out from ~500 selected files, and a
  newline join shreds any filename containing `\n`.
- **Reveal without activation.** Following the playing file uses Finder's
  `reveal` with **no** `activate`, so mpv keeps keyboard focus. The old
  `activateFileViewerSelecting` + refocus dance is only a fallback (failures
  newer than 2 s, file still current). Reverting to activate-and-refocus sends
  every arrow key to Finder on macOS 26/27, where the activation request is
  declined more often.
- `pathCache` / `normalizedPath` / `index(of:)` / `nextFile` / `previousFile`
  are **main-thread-only and unsynchronized**. Calling them inside a
  `queryQueue` / `revealQueue` block (the natural refactor) is an unsynchronized
  Dictionary mutation across threads.
- Automation denial (`-1743`) sets a latch that gates **only** reveal; the cheap
  queries are still attempted, and any success clears the latch — so re-enabling
  the permission in System Settings recovers on the next preview, no relaunch.
- **Sort emulation fallback matrix.** Finder's order is mirrored only when an
  open window's `target` is that exact folder, and only for list view
  (name/kind/modified/created/size) and icon view (same five — but icon-view
  date/size arrangements are emitted `reversed`: Finder renders them
  newest/largest-first and exposes no direction control anywhere). Everything else —
  Desktop, search results, Recents, Tags, smart folders, no window,
  **column view, gallery view**, unmapped columns (Date Added…) — falls back to
  alphabetical. Column view *succeeds* and returns the default, so "sort is
  wrong" there is not a script failure. `reversed` applies to the primary key
  only; the filename tiebreak stays ascending.
- Playlist: playback starts on a provisional alphabetical list, refined
  asynchronously under `sessionID` **and `playlistEpoch`** guards
  (`clearPreviewState()` bumps the former; trash/undo bump the latter, so a
  late refinement can't resurrect a trashed file or clobber an undo
  re-insert). Multi-file selections are refined only when every file shares
  the invoked file's folder. The invoked file is force-inserted into its own
  playlist (provisional *and* refined) — hidden/symlinked videos are missing
  from folder listings, and a playlist without the playing file kills
  navigation and makes Delete close the preview.
- `application(_:open:)` arrives **before** `applicationDidFinishLaunching`
  on a cold launch-by-open (documented AppKit ordering) — URLs are buffered
  in `pendingOpenURLs` and replayed after launch wiring. Calling into the
  controllers from it directly crashes the nil IUOs.
- Trash/undo: Delete is a silent no-op unless `mkvqp.trashEnabled` is on
  (default off). Undo re-inserts at the remembered index only while
  `entry.sessionID == sessionID`. The P key writes tags via
  `(url as NSURL).setResourceValue(_:forKey: .tagNamesKey)` — the Swift
  `URLResourceValues.tagNames` **setter is macOS 26+** and would break the 13.0 target.

### UI (`StatusBarController.swift`)
- **Every NSAlert must go through `NSAlert.runModalInFront()`** (activate +
  `window.level = .floating`). LSUIElement apps are never frontmost, so a bare
  `runModal()` can open behind other windows with no key focus — the app just
  looks hung. After `runModal()` it **hands key focus back to the mpv window**
  when one is playing — activating ourselves otherwise leaves a windowless
  active app swallowing every player key.
- **KeyboardShortcuts is MainActor-isolated but the target is `SWIFT_VERSION = 5.0`**,
  so the compiler will *not* diagnose a call from a background queue — the only
  enforcement is a runtime trap. Reads go through
  `MainActor.assumeIsolated { … }`. Note `NSMenuDelegate.menuWillOpen` is *not*
  MainActor-isolated.
- Shortcut display derives from the stored shortcut and is `Optional` **by
  design** — nil means the user cleared it. Never add a `?? "⇧⌘V"` fallback; it
  would advertise a hotkey that isn't bound.
- The recorder is an NSAlert accessory view. `KeyboardShortcuts.disable(…)`
  before and `.enable(…)` after are required (the global hotkey is otherwise
  armed while recording), as is the async `makeFirstResponder` hop.
- `menu.autoenablesItems = false` — all enabled/checked state is hand-managed,
  and `menuWillOpen` re-reads `SMAppService.mainApp.status` (System Settings can
  toggle it behind the app's back).
- The menu bar icon is **drawn in code** (`makeMenuBarIcon()`, flipped
  coordinate space — y grows downward). `isTemplate = true` is what makes the
  blue "playing" tint and light/dark adaptation work; there is no asset to find.

### App Intents (`MKVQuickPlayIntents.swift`)
- Seven intents (Preview Videos, Next/Previous Video, Move Current Video to
  Trash, Toggle Purple Tag, Stop Preview, Review Folder) plus App Shortcuts
  with Siri phrases. Everything targets the **macOS 13.0 App Intents floor**:
  no `supportedModes`/`openAppWhenRun` (the background default is right for
  driving an external mpv window), and **no `@Parameter` option beyond
  `title:`** — every overload carrying `description:` or
  `supportedContentTypes:` is macOS 15+, which is why the file parameters are
  untyped and filtered in code (`isVideoFile`, directory check).
- Intents run **in-process**; macOS background-launches the app when needed.
  Every `perform()` is `@MainActor` and calls the **intent facade** extension
  at the bottom of AppDelegate.swift. The facade lives in that file so it can
  reach the private internals — new intent code goes through it, never around
  it. Intents always pass `allowToggle: false` ("preview" from an automation
  must never toggle-close).
- The Delete-key safety gate (`mkvqp.trashEnabled`) lives in the **onTrash
  key-callback wiring**, not in `trashCurrentAndAdvance()` — the Trash intent
  bypasses it on purpose.
- After changing any intent metadata, replace the copy in /Applications and
  launch it once before expecting Shortcuts/Spotlight to update; stray
  DerivedData copies registered with LaunchServices cause ghost actions.
- Finder Quick Action = a user-imported shortcut wrapping *Preview Videos*
  (recipe in README); there is deliberately no Finder Sync/Action extension.

### Watch folders (`WatchFolderManager.swift`)
- One FSEventStream per folder (file events, 2 s latency, `sinceNow`) + a
  reconcile scan on arm/mount/wake/anomalous flags and on a 30 s timer for
  non-local volumes. **No DispatchSource** — an open fd per folder would
  block ejecting the external SSDs these folders live on.
- **Settle gate** before a file is offered: size+mtime stable across 2 polls
  AND ≥3 s event-quiet AND nonzero size (Finder shows a copy the moment it
  *starts*, and arrivals feed a Delete-key workflow). Batches are offered
  after 5 s of folder quiet and marked seen at offer time; adding a folder
  seeds the seen-set silently (pre-existing videos are not "new").
- Folders persist as bookmarks (`mkvqp.watchFolders` in UserDefaults);
  seen-sets live in Application Support `watch-seen.json`. An unresolvable
  folder goes dormant and re-arms on the next mount/wake.
- Review sessions start via `AppDelegate.startBatchReview` — the batch is the
  authority on membership, so the Finder-sort refinement deliberately does
  not run there.
- FSEvents contexts hold an **unretained** self: the manager is owned by
  AppDelegate for the app's lifetime and must never be deallocated or
  recreated.

## Building (dev)

Requires **Xcode 26+** (KeyboardShortcuts 3.x is a Swift 6.2 package).

```bash
cd macos
xcodebuild -project MKVQuickPlay.xcodeproj -scheme MKVQuickPlay -configuration Release build
```

Dependencies (SwiftPM, pinned `upToNextMajorVersion`, see `Package.resolved`):
- **KeyboardShortcuts 3.1.0** — floor is hard: earlier versions' recorder does
  not capture keys and its ✕ does nothing on macOS 26/27.
- **Sparkle 2.10.0** — auto-updates.

## Releasing (REQUIRED process for every update)

Every public update must be **Developer ID-signed and notarized**. Never publish
a development-signed build.

1. Make the changes.
2. Bump **both** `CFBundleShortVersionString` *and* `CFBundleVersion` in
   `macos/MKVQuickPlay/Info.plist`. Sparkle compares **build numbers**, so a
   release without a `CFBundleVersion` bump is never offered as an update.
   ⚠️ `Info.plist` is the **only** live version source (`GENERATE_INFOPLIST_FILE = NO`).
   The pbxproj's `MARKETING_VERSION = 1.0.0` / `CURRENT_PROJECT_VERSION = 1` are
   dead decoys — bumping them in Xcode's UI changes nothing.
3. Add a `CHANGELOG.md` section. The heading must be bracketed — `## [2.5.1]` —
   or the appcast release notes come out empty.
4. Commit **and push** (the release refuses a dirty or unpushed tree).
5. `scripts/release.sh`

Flags: `--no-publish` (build + notarize only, skips all guards — for mid-dev
testing) and `--force` (allows re-releasing an existing tag). ⚠️ `--force`
uploads new binaries but leaves the tag pointing at the **old** commit.

Publish-path guards, in order: clean tree → HEAD pushed to upstream → tag does
not already exist → CFBundleVersion exceeds the published appcast's (the
forgotten-build-bump release would publish a dead update; `--force` skips the
version guards for same-version re-releases). Unknown flags abort.
`update-appcast.sh` and `update-cask.sh` each refuse to run standalone for a
GitHub release that doesn't exist, and the appcast guard is version-aware
(equal build allowed only when re-signing the same version).

After upload the pipeline runs `scripts/update-cask.sh` then
`scripts/update-appcast.sh`, and **both are failure-tolerant** — `release.sh`
can print "Done." having published a binary with a stale cask and/or no appcast
entry. Check its output. Recovery = re-run the sub-script by hand **while
`build/release/` still exists** (the next `release.sh` deletes it).

- `update-appcast.sh` rewrites `docs/appcast.xml` with exactly **one** `<item>`
  (no version history), signs the zip with the EdDSA key from the login
  keychain, and **commits + pushes by itself** with a bare `git commit` of the
  whole index — don't leave unrelated files staged when running it.
  `<sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>` is
  hardcoded there and duplicates `MACOSX_DEPLOYMENT_TARGET`; raise both or neither.
- `update-cask.sh` bumps the `tehshawn/homebrew-tap` cask (version + sha256) and
  gates `auto_updates true` on the *previously published* version being ≥ 2.4.0
  (the first Sparkle build) so pre-Sparkle installs aren't stranded. Its
  verification checks version/sha only, not the flag; it relies on exact
  two-space cask indentation.
- `release.sh` also uploads a **dSYM** asset, needed to symbolicate crash reports.

### One-time setup

- Developer ID cert: "Developer ID Application: Shawn McEntyre (BVUHD2VQU7)".
- **Notarization uses an App Store Connect API key**, stored as keychain profile
  `MKVQuickPlay-Notary`:

  ```bash
  xcrun notarytool store-credentials "MKVQuickPlay-Notary"
  # prompts for: path to AuthKey_XXXXXXXXXX.p8, Key ID, Issuer ID (UUID)
  ```

  The `.p8` is **downloadable exactly once** and is not kept in this repo or on
  disk (`store-credentials` copies the material into the keychain). If the
  keychain item is lost, the key cannot be re-downloaded — mint a new one in
  App Store Connect ▸ Users and Access ▸ Integrations and re-run the command.
  Verify with `xcrun notarytool history --keychain-profile MKVQuickPlay-Notary`.
- Sparkle's EdDSA **private key** lives in the login keychain; its public half is
  `SUPublicEDKey` in Info.plist. Losing it means existing users can never be
  updated again. The keychain ACL trusts `sign_update` **by absolute path** under
  DerivedData, so a DerivedData wipe (or a differently-hashed path) triggers a
  keychain prompt or an "appcast not generated" warning — run
  `xcodebuild -resolvePackageDependencies` and re-run interactively.
- `gh` CLI authenticated; remote is `tehshawn/mkvquickplay`.

Notarization and timestamped signing need network access to Apple, so
`scripts/release.sh` must run on the developer's Mac — **a cloud/sandboxed
session cannot release.**

## App icons — two pipelines, same name

1. `macos/MKVQuickPlay/AppIcon.icon/` — Icon Composer document (`icon.json` +
   4 SVG layers), the **macOS 26+ Liquid Glass** icon. Edit in Icon Composer.
2. `macos/MKVQuickPlay/Assets.xcassets/AppIcon.appiconset/` — 10 flat PNGs for
   **macOS 13–25**, regenerated with `swift scripts/icongen.swift <appiconset-dir>`.

Both must stay committed: deleting the appiconset drops the icon on older
macOS; a missing `AppIcon.icon` breaks the Resources build phase on a clean clone.

## Repo traps

- **`.gitignore` anchoring.** Line `/MKVQuickPlay*/` **must keep its leading
  slash**. A pattern whose only slash is trailing matches the basename at *every*
  level, so unanchored `MKVQuickPlay*/` also matched `macos/MKVQuickPlay/` — the
  whole app source directory. The failure is silent: already-tracked files keep
  working and `git status` stays clean, so only **newly added** files vanish.
  This bit twice (`MKVQuickPlay*/`, and `*.xcworkspace` hiding
  `project.xcworkspace/`, which holds `Package.resolved`) and is why
  `AppIcon.icon/` went uncommitted for a whole release. After adding any new
  file under `macos/`, confirm with `git status --ignored` that it isn't ignored.
- `NSServices` in Info.plist declares `NSSendFileTypes = public.data`, so the
  service appears for **every** file and video filtering happens in code
  (`isVideoFile`). `NSMessage` must match the `@objc(previewVideo:userData:error:)`
  selector and `NSPortName` the executable name.
