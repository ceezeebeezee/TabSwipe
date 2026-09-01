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
```

**Always pass `--scratch-path`.** `~/Projects` is inside a Google Drive synced
folder, and Drive's virtual filesystem does not honour SQLite locking, so
SwiftPM's `build.db` fails intermittently with "disk I/O error" and freshly
linked binaries silently fail to materialise. `build.sh` sets this already.

## Architecture

- `Sources/MultitouchSupport.swift` — runtime binding to the private
  MultitouchSupport framework, loaded with `dlopen`
- `Sources/SwipeDetector.swift` — contact frames to swipe events
- `Sources/GestureEngine.swift` — device lifecycle, sleep/wake recovery,
  keystroke output
- `Sources/Settings.swift` — UserDefaults-backed preferences
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

`build.sh` needs a Developer ID Application certificate and a notarytool
keychain profile named `TabSwipe-Notarize`. It runs tests, builds, assembles
the bundle, embeds and signs Sparkle, signs and notarizes the app, staples it,
builds and notarizes the DMG, then writes `TabSwipe-<version>.zip` — the
archive Sparkle downloads, which is _not_ the DMG — and prints its EdDSA
signature and length.

A release spans two repos: this one and the site repo that serves
`czbz.ai/tabswipe/`.

1. Bump `VERSION` at the top of `build.sh`. It is the single source for both
   plist version keys and what Sparkle compares against the appcast.
2. Run `./build.sh` and keep the printed `edSignature` and `length`.
3. Copy the DMG and the zip into the site repo's `tabswipe/` directory.
4. Update the `<enclosure>` in `tabswipe/appcast.xml` with that signature and
   length.
5. **Re-sign the feed**: `sign_update tabswipe/appcast.xml`. Sparkle's tools
   live under
   `~/Library/Caches/TabSwipe-build/artifacts/sparkle/Sparkle/bin/`.
6. Update the hardcoded download size in `tabswipe/index.html`.
7. Commit both repos and deploy the site.
8. Verify against the live site, not the local copy: fetch the appcast and zip
   from `czbz.ai`, check the declared length matches the served bytes, and run
   `sign_update --verify <zip> <signature>`.

### Step 5 is the one that breaks silently

The app sets `SURequireSignedFeed`, so `appcast.xml` carries its own signature
in a trailer comment as well as the per-payload one. **Any** edit invalidates
that trailer and Sparkle then refuses the whole feed. Nothing fails on the
publishing side — the build succeeds, the deploy succeeds, and updates just
stop working for everyone. Re-sign after every edit.

The private signing key is in the login keychain and is backed up. Losing it
means never shipping an update again, because installed copies only accept
what verifies against the public key compiled into them. Export with
`generate_keys -x`, import with `-f`. Do not regenerate or rotate it.

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

The download page, terms, DMG, update zip and appcast live in the site repo
under `tabswipe/`. Two things there drift silently and need updating with the
app: the hardcoded download size, and `menu.svg`, which is a hand-drawn
illustration of the menu — change the menu, redraw it. The SVGs are
illustrations rather than screenshots because `LSUIElement` apps are invisible
to macOS's app-access resolver and cannot be captured.

The privacy section makes specific factual claims about what the app sends.
It was rewritten when Sparkle landed, because "contains no networking code at
all" stopped being true. Keep it matching the code.
