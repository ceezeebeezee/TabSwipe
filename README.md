# TabSwipe

Three-finger trackpad swipe to switch Google Chrome tabs on macOS.

A ~1,600-line Swift menu bar app. No window, no preferences pane, no account,
no update checks, no network code of any kind.

**[Download the signed, notarized app →](https://czbz.ai/tabswipe)**

## Requirements

- macOS 13 Ventura or later
- Apple Silicon (M1 or later) — the release build is arm64 only
- Google Chrome

## How it works

`NSEvent` global monitors never see other apps' gesture events, and
`CGEventTap` never sees three-finger swipes that the WindowServer has already
claimed for Spaces and Mission Control. The only way to observe raw trackpad
contacts system-wide is Apple's private `MultitouchSupport` framework, which
every gesture utility on macOS uses for exactly this reason.

`Sources/MultitouchSupport.swift` binds it at runtime via `dlopen`/`dlsym`
rather than hard-linking, so if a future macOS renames a symbol the app still
launches — gestures disable and the menu shows a warning — instead of being
killed by dyld before `main()`.

Detected swipes are translated into a single Ctrl+Tab / Ctrl+Shift+Tab
keystroke sent to Chrome via `CGEvent`, which is why the app needs
Accessibility permission.

This is also why TabSwipe is not on the Mac App Store: private frameworks are
prohibited by App Review guideline 2.5.1, and sandboxed apps cannot use the
Accessibility APIs to control another application. Distribution is a direct
download, signed with a Developer ID certificate and notarized by Apple.

## Layout

| Path                              | What                                                    |
| --------------------------------- | ------------------------------------------------------- |
| `Sources/MultitouchSupport.swift` | Runtime binding to the private framework                |
| `Sources/SwipeDetector.swift`     | Turns contact frames into swipe events                  |
| `Sources/GestureEngine.swift`     | Device lifecycle, sleep/wake recovery, keystroke output |
| `Sources/Settings.swift`          | UserDefaults-backed preferences                         |
| `App/App.swift`                   | Menu bar UI and permission prompts                      |
| `Tests/TabSwipeTests.swift`       | Standalone test executable — no Xcode required          |

## Building

```bash
./build.sh
```

Runs the tests, builds a release binary, assembles `TabSwipe.app`, signs it
with a Developer ID certificate if one is present (falling back to self-signed
or ad-hoc for local development), notarizes and staples both the app and the
DMG, and verifies the result with `codesign` and `spctl`.

Build state deliberately lives in `~/Library/Caches/TabSwipe-build` rather than
`.build`, because this project sits in a synced folder and SwiftPM's SQLite
build database does not survive that.

## Setup note

macOS claims three-finger swipes for Mission Control and full-screen app
switching. Move both to four fingers in System Settings → Trackpad → More
Gestures, or they will fight TabSwipe. The app offers to open that pane on
first run.

## Contributing

Issues are welcome — bug reports especially, since I can only test on my own
hardware.

Pull requests are unlikely to be merged. This is a personal project that does
one thing and is finished; I would rather it stay small than grow features.
If you want it to do something else, forking is genuinely the right answer and
the licence explicitly allows it.

## Licence

[Apache License 2.0](LICENSE). You may use, modify, distribute and sell this
code, including in closed-source and commercial work, provided you retain the
copyright and licence notices and state any changes you made. The licence
includes an express patent grant and does not permit use of the author's name
or trademarks to endorse your fork.

Provided as is, without warranty of any kind. See also the
[terms of use](https://czbz.ai/tabswipe/terms) covering the distributed binary.
