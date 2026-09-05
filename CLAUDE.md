# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

TabSwipe is a macOS menu bar app: a three-finger trackpad swipe moves Chrome
one tab. No window, no preferences pane. Swift + AppKit, SwiftPM, no Xcode
project.

## Commands

```bash
./build.sh                                    # the whole release pipeline (see below)
swift build -c release \
  --scratch-path ~/Library/Caches/TabSwipe-build --product TabSwipe   # compile check
swift run -c release \
  --scratch-path ~/Library/Caches/TabSwipe-build TabSwipeTests        # tests
swift generate-icon.swift && iconutil -c icns /tmp/TabSwipe.iconset -o TabSwipe.icns
/usr/bin/log show --predicate 'subsystem == "com.tabswipe.app"' --last 1h    # persisted app log
```

**Spell out `/usr/bin/log`.** `log` is a zsh builtin, so a bare `log show`
fails with "too many arguments" — and with stderr hidden it looks like an
empty log.

**Always pass `--scratch-path`.** `~/Projects` is inside a Google Drive synced
folder, and Drive's virtual filesystem does not honour SQLite locking, so
SwiftPM's `build.db` fails intermittently with "disk I/O error" and freshly
linked binaries silently fail to materialise. `build.sh` sets this already.

## Architecture

- `Sources/MultitouchSupport.swift` — runtime binding to the private
  MultitouchSupport framework, loaded with `dlopen`
- `Sources/SwipeDetector.swift` — contact frames to swipe events
- `Sources/GestureEngine.swift` — device lifecycle, sleep/wake recovery,
  keystroke output. Trackpads are re-enumerated whenever IOKit reports a
  multitouch device arriving or leaving, and every 20 s as a safety net: a
  Bluetooth Magic Trackpad reconnects seconds after the wake re-attach passes,
  and until 1.5 nothing ever looked again — the built-in trackpad worked and
  the external one was dead until relaunch. That was every "TabSwipe died"
  report. "Chrome" means any `com.google.Chrome*` frontmost app:
  installed web apps (Gmail, Calendar, "Open as window") are separate app-shim
  processes that own their windows, so the keystroke goes to the shim's pid
- `Sources/Settings.swift` — UserDefaults-backed preferences
- `Sources/Log.swift` — unified logging plus the opt-in debug log file
- `App/App.swift` — the entire UI: status item, menu, first-run install,
  welcome dialog, Sparkle wiring, uninstall
- `LetsMove/` — vendored, Objective-C with manual retain/release, so it is
  compiled with `-fno-objc-arc`
- `build.sh` — build, bundle, sign, notarize, staple, package
- `generate-icon.swift` — draws `TabSwipe.icns`; the same mark as the menu bar
  glyph and the website

**This app cannot ship on the Mac App Store, ever.** It `dlopen`s a private
framework (App Review guideline 2.5.1) and drives Chrome through the
Accessibility API, which a sandboxed app cannot do. Notarization is a malware
scan and is unrelated to App Review. Do not "fix" this.

**arm64 only, deliberately.** A universal build was implemented and reverted on
request. `build.sh` prints `lipo -archs` before signing.

## Releasing

Distribution is a signed **installer package**, not a disk image. Installer.app
places the app, a postinstall launches it, and — because a package does not set
the quarantine flag on what it installs — the user never sees Gatekeeper's
"downloaded from the Internet" dialog. Updates are separate: Sparkle downloads
`TabSwipe-<version>.zip` and swaps the bundle in place; nobody gets an
installer for an update.

`build.sh` needs, in the login keychain:

- a **Developer ID Application** certificate (codesigns the app),
- a **Developer ID Installer** certificate (productsigns the pkg — a different
  certificate type; the current one expires **2027-02-01**, and packages
  already notarized keep working after expiry, but new releases need renewal),
- a notarytool profile named `TabSwipe-Notarize` (if it goes missing, only the
  user can recreate it — it needs their Apple ID and an app-specific password:
  `xcrun notarytool store-credentials "TabSwipe-Notarize" --apple-id … --team-id GFJX8GLA7X`).

**Do not build with the Mac locked.** A locked screen locks the login
keychain, notarytool then reports the profile as missing, and `build.sh`
refuses to continue (it used to warn and produce an unnotarized package that
Gatekeeper rejects for every downloader — that shipped once, for minutes, in
1.4). If the profile "disappears", unlock the Mac and retry before recreating
anything. `ALLOW_UNNOTARIZED=1` bypasses the refusal for local test builds only.

The script runs tests, builds, embeds and signs Sparkle, notarizes and staples
the app, builds/signs/notarizes/staples `TabSwipe.pkg`, writes the update zip,
and generates a **signed appcast** at `dist/appcast.xml` via `generate_appcast`
(release notes come from `release-notes/<version>.html`, embedded into the
feed).

A release spans two repos — this one and the site repo serving
`czbz.ai/tabswipe/`:

1. Bump `VERSION` at the top of `build.sh` (single source for both plist
   version keys and the appcast comparison). Add
   `release-notes/<version>.html`.
2. Run `./build.sh`.
3. Copy `TabSwipe.pkg`, `TabSwipe-<version>.zip` and `dist/appcast.xml` into
   the site repo's `tabswipe/` directory. `chmod 644` the copies.
4. Update the hardcoded download size in `tabswipe/index.html`.
5. Commit both repos and deploy the site.
6. Verify against the **live** site, not the local copy: download the pkg from
   `czbz.ai`, set a quarantine xattr, and check `spctl -a -t install` accepts
   it; fetch the appcast and zip and run
   `sign_update --verify <zip> <signature>` with the enclosure signature.
   Sparkle's tools live under
   `~/Library/Caches/TabSwipe-build/artifacts/sparkle/Sparkle/bin/`.

### Never hand-edit appcast.xml

The app sets `SURequireSignedFeed`: the feed carries its own EdDSA signature in
a trailer comment, and **any** edit invalidates it — Sparkle then refuses the
whole feed and updates stop for everyone, with nothing failing on the
publishing side. The appcast is generated and signed by `build.sh`; to change
it, change the inputs (release notes, version) and rebuild.

The private signing key is in the login keychain and is backed up. Losing it
means never shipping an update again, because installed copies only accept
what verifies against the public key compiled into them. Export with
`generate_keys -x`, import with `-f`. Do not regenerate or rotate it.

**`/Applications/TabSwipe.app` is root-owned after a pkg install**, so a
plain `ditto` over it fails with permission errors — kill the process first
and you have simply stopped the user's app. To put a new build there without
the user, there is no path: use the pkg (Installer.app) or Check for Updates.
Sparkle copes with the root-owned bundle by asking for an admin password.

### Testing an update end to end

Copy the built `TabSwipe.app` to `/tmp/updtest/`, patch both version keys to
`0.9` and _remove_ `SUAllowsAutomaticUpdates` with plutil, re-sign the outer
bundle, then `defaults write com.tabswipe.app SUEnableAutomaticChecks -bool YES`,
`SUAutomaticallyUpdate -bool YES`, `SUHasLaunchedBefore -bool YES` and launch.
It checks the live feed within ~15 s, stages silently, and installs on quit —
verify the on-disk bundle became the new version. This exercises every stage
except the "Install and Relaunch" button UI. Snapshot/restore the defaults
domain around the test, and clean up `~/Library/Caches/com.tabswipe.app*`.

## Logging and Debug Mode

Three tiers, chosen by what survives: `Log.notice`/`Log.error` go to the
unified log at a level macOS persists (lifecycle: start, sleep/wake, re-attach,
menu changes); `Log.info` is memory-only; `Log.debug` is silent unless
**Troubleshooting › Debug Logging** is on, in which case everything — including
the notices — is also appended to `~/Library/Logs/TabSwipe/TabSwipe.log`
(rolls over at 4 MB to `.log.1`; Uninstall removes the directory). The setting
persists across relaunches on purpose: the failures worth catching take a day
of sleep/wake cycles to appear.

What the debug log records: a header (versions, model, Accessibility state,
each multitouch device with id/family/built-in/running), every gesture arm,
suppression, lift and fire with the pid the keystroke went to, frontmost-app
changes as seen by the pid cache, re-attach passes, and a heartbeat every
minute with the frame count and "attached N of M enumerated". A heartbeat with
zero frames while the user is swiping means the trackpad has stopped
delivering — and if M > N, the app is attached to fewer devices than exist; frames with "Chrome is not
the frontmost app" means the pid cache is the problem; a fire with a pid means
the app did its job and Chrome ignored the keystroke.

`Log.debug` takes an autoclosure — callers on the touch-callback path pay
nothing when the mode is off. File writes go through a serial queue, never on
the caller's thread, and the debug lines from the callback are collected under
the lock but emitted after it is released.

## Gotchas

**`SUAllowsAutomaticUpdates` is false and that is load-bearing.** When Sparkle
is allowed to stage an update for install-on-quit, it leaves `Autoupdate` and
`Updater.app` resident until the host exits. For a menu bar app nobody ever
quits, that means two processes sitting around for days — WhatsApp does exactly
this. With installs strictly user-initiated they live for seconds. The weekly
check itself is only a timer inside our own process; Sparkle links as a dylib
and registers no launchd job.

**SwiftPM has no notion of an app bundle**, so `build.sh` embeds Sparkle by
hand: `ditto` (not `cp`, which is why the versioned framework's symlinks
survive and its signature still validates), strip the XPC services (they exist
for sandboxed apps, which we cannot be), add the `@executable_path/../Frameworks`
rpath SwiftPM omits, and sign inside-out — framework first, app last, because
signing a bundle seals the hashes of everything already inside it.

**The package must stay non-relocatable.** `pkgbuild` defaults
`BundleIsRelocatable` to true, which makes Installer ask LaunchServices for an
existing copy of the bundle and "update" it wherever it lives — a dev checkout,
the Trash — instead of installing to /Applications. Uninstall + reinstall hit
exactly this: the payload landed in the project directory as root and
/Applications got nothing. `build.sh` stages the app alone, generates the
component plist with `--analyze`, and forces the flag off; when touching the
packaging, verify the expanded pkg's PackageInfo says `relocatable="false"`.
Corollary: launching the build-directory copy directly (Spotlight finds it) is
how you get the LetsMove move-to-Applications dialog — that is correct
behaviour, not a bug.

**The pkg postinstall must drop to the console user before launching.** The
installer runs as root; a bare `open` there would run TabSwipe as root, put its
preferences in root's home, and record the login item and Accessibility grant
against the wrong user. It uses `launchctl asuser` with the owner of
`/dev/console`.

**LetsMove's dialog copy is ours, not upstream's.** The defaults in
`LetsMove/PFMoveApplication.m` (first person, no app name, password warning up
front) were replaced in the `#define`s at the top. The dialog is a safety net
only — the pkg always installs to /Applications — so it fires exactly when the
app runs from an odd location. Keep the rewritten strings if the vendored copy
is ever refreshed from upstream.

**The Accessibility grant is keyed to the code-signing identity**, not the
path. With a stable Developer ID, replacing the app in `/Applications` keeps
the permission, which is why updates do not re-prompt. Ad-hoc signing changes
identity on every rebuild, so during local development you must remove and
re-add TabSwipe in System Settings after each build.

**Only register the login item from an Applications folder.** A login item
records the path it was registered from, so registering while running from a
download or disk image enrols a bundle that is about to vanish, and macOS keeps
showing the dead entry in System Settings where it is very hard to clear.

**macOS 26 decorates recognised menu items with its own symbols** — "About"
picks up an ⓘ. The global switch for that belongs to the user, so `main()`
writes `NSMenuEnableActionImages` into the argument domain instead: highest
priority, in memory only, scoped to this process. The menu also sets
`showsStateColumn = false` for flush-left items, so the two stateful entries
carry their state in their titles; submenus keep their own columns.

**Uninstall must unregister the login item first**, while the bundle still
exists — afterwards `SMAppService` cannot undo it. It then clears the defaults
domain with `removePersistentDomain` (deleting the plist alone does not work,
the preferences daemon writes it back), removes the five support paths listed
in `supportFileURLs`, trashes the app, and points the user at the Accessibility
entry, which no app can remove for itself.

**If `security find-identity -v` does not list the Developer ID**, it is a
certificate chain problem, not a missing key. Run `find-identity` _without_
`-v`: if the identity appears there but not in the valid list, the Developer ID
G2 intermediate CA is missing (Xcode installs it; a Command Line Tools-only Mac
may not have it). Install `DeveloperIDG2CA.cer` and `AppleRootCA-G2.cer`. Do
not revoke the certificate.

## Website

The download page, terms, `TabSwipe.pkg`, update zip and appcast live in the
site repo under `tabswipe/`. The download link is dispensed by an email-gate
script in `index.html` whose `PKG` variable holds the path — keep it and the
plain fallback link in sync if the artifact name ever changes. Two things there
drift silently and need updating with the app: the hardcoded download size, and
`menu.svg`, which is a hand-drawn illustration of the menu — change the menu,
redraw it. The SVGs are illustrations rather than screenshots because
`LSUIElement` apps are invisible to macOS's app-access resolver and cannot be
captured.

The privacy section makes specific factual claims about what the app sends.
It was rewritten when Sparkle landed, because "contains no networking code at
all" stopped being true. Keep it matching the code.
