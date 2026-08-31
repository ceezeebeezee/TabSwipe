#!/bin/bash
set -e

cd "$(dirname "$0")"

# Single source of truth for the release version. Sparkle compares this against
# the appcast to decide whether an update exists, so bumping it here is what
# makes a build "new" to everyone already running TabSwipe.
VERSION="1.0"

APP_NAME="TabSwipe"
APP_BUNDLE="$APP_NAME.app"
DMG_NAME="$APP_NAME.dmg"
ZIP_NAME="$APP_NAME-$VERSION.zip"   # what Sparkle downloads
TEAM_ID="GFJX8GLA7X"
NOTARIZE_PROFILE="TabSwipe-Notarize"

# Public half of the EdDSA keypair from Sparkle's generate_keys. The private
# half lives in the login keychain and never leaves this machine; sign_update
# reads it when publishing. Updates that do not verify against this key are
# rejected, so a compromised czbz.ai cannot push code to users.
SU_PUBLIC_KEY="eLIQXX+ZAxPKcNygk5MeXRHXf7zJl0/CJDcMee+kpSw="
SU_FEED_URL="https://czbz.ai/tabswipe/appcast.xml"

# ~/Projects is inside a Google Drive synced folder. Drive's virtual filesystem
# does not honour SQLite's locking and fsync guarantees, so SwiftPM's build.db
# intermittently fails with "disk I/O error" and freshly linked binaries fail to
# materialise. Keep every byte of build state on real local disk, outside the
# synced tree. (Also stops Drive uploading thousands of object files per build.)
SCRATCH="$HOME/Library/Caches/TabSwipe-build"
mkdir -p "$SCRATCH"

echo "Running tests..."
swift run -c release --scratch-path "$SCRATCH" TabSwipeTests

echo "Building $APP_NAME..."
swift build -c release --scratch-path "$SCRATCH" --product TabSwipe

BUILD_DIR=$(swift build -c release --scratch-path "$SCRATCH" --product TabSwipe --show-bin-path)

echo "Creating $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

if [ -f "TabSwipe.icns" ]; then
    cp TabSwipe.icns "$APP_BUNDLE/Contents/Resources/TabSwipe.icns"
fi

# --- Embed Sparkle ---
# SwiftPM links against the XCFramework but has no notion of an app bundle, so
# the framework has to be placed and signed by hand. ditto (not cp) preserves
# the symlink farm a versioned framework needs for its signature to validate.
SPARKLE_FW="$SCRATCH/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ ! -d "$SPARKLE_FW" ]; then
    echo "✗ Sparkle.framework not found. Run: swift package resolve --scratch-path $SCRATCH"
    exit 1
fi

mkdir -p "$APP_BUNDLE/Contents/Frameworks"
ditto "$SPARKLE_FW" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

SPARKLE_VERSION_DIR="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/Current"

# XPC Services exist to let *sandboxed* apps delegate downloading and
# installing. TabSwipe cannot be sandboxed (it drives Chrome through the
# Accessibility API), so they are dead weight — Sparkle's own docs say to
# remove them. Headers and module maps are build-time only.
rm -rf "$SPARKLE_VERSION_DIR/XPCServices"
rm -rf "$SPARKLE_VERSION_DIR/Headers" "$SPARKLE_VERSION_DIR/PrivateHeaders" "$SPARKLE_VERSION_DIR/Modules"
rm -rf "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Headers" \
       "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/PrivateHeaders" \
       "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Modules" \
       "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/XPCServices"

# The executable records Sparkle's install name as @rpath/... but SwiftPM adds
# no matching LC_RPATH, so without this the app dies at launch with "Library
# not loaded". Must happen before signing: it rewrites the Mach-O header.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null

# Unquoted heredoc: $VERSION and the Sparkle settings are interpolated.
cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>TabSwipe</string>
    <key>CFBundleDisplayName</key>
    <string>TabSwipe</string>
    <key>CFBundleIdentifier</key>
    <string>com.tabswipe.app</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>TabSwipe</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>TabSwipe</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright 2026 Caesar Sengupta. Licensed under Apache 2.0.</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>SUFeedURL</key>
    <string>$SU_FEED_URL</string>
    <key>SUPublicEDKey</key>
    <string>$SU_PUBLIC_KEY</string>
    <!-- Weekly. Sparkle's default is 86400 (daily); its floor is one hour. -->
    <key>SUScheduledCheckInterval</key>
    <integer>604800</integer>
    <!-- SUEnableAutomaticChecks is deliberately absent: with it unset Sparkle
         asks the user, on second launch, whether to check automatically.
         Opting in beats deciding for them for an app that used to make no
         network connections at all. -->
    <!-- No silent background installs, and no offering them to the user. This
         is what keeps TabSwipe free of resident processes: when Sparkle stages
         an update to apply on quit, it leaves Autoupdate and Updater.app
         running until the host exits — for an app people never quit that means
         two processes resident for days (WhatsApp does exactly this). With
         installs strictly user-initiated, those helpers spawn, swap the bundle,
         relaunch and exit within seconds. The weekly check itself is just a
         timer inside TabSwipe's own process. -->
    <key>SUAllowsAutomaticUpdates</key>
    <false/>
</dict>
</plist>
PLIST

echo "Architectures in the built binary:"
lipo -archs "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | sed 's/^/   /'

# --- Sign the app ---
# Prefer Developer ID Application certificate (for distribution)
# Fall back to self-signed cert (for local dev)
DEV_ID_CERT=$(security find-identity -v -p codesigning | grep "Developer ID Application" | grep "$TEAM_ID" | head -1 | awk -F'"' '{print $2}')

# Sparkle arrives signed by the Sparkle project, and stripping the XPC services
# invalidated that signature — so everything nested gets re-signed with our own
# identity. Order matters: innermost first, outermost last, because signing a
# bundle seals the hashes of everything already inside it. Signing the app first
# would bake in hashes that the framework signature then invalidates.
sign_sparkle() {
    local identity="$1"
    shift
    local fw="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    for nested in \
        "$fw/Versions/Current/Updater.app" \
        "$fw/Versions/Current/Autoupdate"
    do
        [ -e "$nested" ] && codesign --force "$@" --sign "$identity" "$nested"
    done
    codesign --force "$@" --sign "$identity" "$fw"
}

if [ -n "$DEV_ID_CERT" ]; then
    echo "Signing with: $DEV_ID_CERT"

    # No entitlements needed: plain Swift/AppKit app, no JIT
    sign_sparkle "$DEV_ID_CERT" --options runtime --timestamp
    codesign --force --options runtime --timestamp \
        --sign "$DEV_ID_CERT" \
        "$APP_BUNDLE"

    SIGN_MODE="developer-id"
    echo "✓ Signed with Developer ID + hardened runtime (app + Sparkle)"
elif security find-identity -v -p codesigning | grep -q "TabSwipe Signing"; then
    sign_sparkle "TabSwipe Signing"
    codesign --sign "TabSwipe Signing" --force "$APP_BUNDLE"
    SIGN_MODE="self-signed"
    echo "✓ Signed with self-signed cert (for local use only)"
else
    sign_sparkle -
    codesign --sign - --force "$APP_BUNDLE"
    SIGN_MODE="ad-hoc"
    echo "⚠ Ad-hoc signed — the code-signing identity changes on EVERY rebuild."
    echo "  macOS keys the Accessibility grant to that identity, so after each"
    echo "  rebuild you must REMOVE and RE-ADD TabSwipe in System Settings →"
    echo "  Privacy & Security → Accessibility (the stale checkbox won't work)."
    echo "  For a stable local-dev identity, create a self-signed code-signing"
    echo "  certificate named 'TabSwipe Signing' in Keychain Access."
fi

# --- Notarization setup ---
NOTARY_READY="no"
if [ "$SIGN_MODE" = "developer-id" ]; then
    if xcrun notarytool history --keychain-profile "$NOTARIZE_PROFILE" >/dev/null 2>&1; then
        NOTARY_READY="yes"
    else
        echo ""
        echo "⚠ Notary credentials not found in keychain."
        echo "  Set up with: xcrun notarytool store-credentials \"$NOTARIZE_PROFILE\" \\"
        echo "                  --apple-id <your-apple-id> --team-id $TEAM_ID"
    fi
fi

# --- Notarize the app, then staple the ticket INTO the bundle ---
# Stapling only the DMG leaves the app unverifiable offline once a user has
# dragged it out to /Applications: the ticket lives on the disk image, not in
# the thing they actually run. Notarizing a zip of the bundle lets us staple
# the ticket into TabSwipe.app itself, before it is packaged.
APP_NOTARIZED="skipped"
if [ "$NOTARY_READY" = "yes" ]; then
    echo ""
    echo "Notarizing $APP_BUNDLE (this can take 1-10 minutes)..."
    ZIP_PATH="/tmp/$APP_NAME-notarize.zip"
    rm -f "$ZIP_PATH"
    ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

    if xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARIZE_PROFILE" --wait; then
        xcrun stapler staple "$APP_BUNDLE"
        xcrun stapler validate "$APP_BUNDLE"
        APP_NOTARIZED="yes"
        echo "✓ Ticket stapled into $APP_BUNDLE"
    else
        APP_NOTARIZED="failed"
        echo "⚠ App notarization failed. For details:"
        echo "   xcrun notarytool submit $ZIP_PATH --keychain-profile $NOTARIZE_PROFILE --wait --verbose"
    fi
    rm -f "$ZIP_PATH"
fi

# --- Create DMG (now containing the stapled app) ---
echo ""
echo "Creating $DMG_NAME..."
DMG_STAGING="/tmp/TabSwipe-dmg"
rm -rf "$DMG_STAGING" "$DMG_NAME"
mkdir -p "$DMG_STAGING"

cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

cat > "$DMG_STAGING/FIRST TIME SETUP.txt" << 'README'
TabSwipe — 3-Finger Tab Switch for Chrome
==========================================

INSTALL:
  Drag TabSwipe.app to the Applications folder.

FIRST RUN:
  Open TabSwipe from Applications (or Spotlight).
  Grant Accessibility permission when prompted.
  The 3-finger icon will appear in your menu bar.

IMPORTANT — TRACKPAD SETTINGS:
  macOS also uses 3-finger swipes for Mission Control and switching
  full-screen apps. Set those to FOUR fingers so they don't clash:
  System Settings → Trackpad → More Gestures →
    "Swipe between full-screen applications" → Four Fingers
    "Mission Control" → Four Fingers

HOW IT WORKS:
  3-finger swipe left/right on your trackpad to switch Chrome tabs.
  Click the menu bar icon to adjust swipe distance and direction.

UNINSTALL:
  Click the menu bar icon and choose "Uninstall TabSwipe".
  It removes the login item and its settings, moves itself
  to the Trash, and shows you where to clear its leftover
  Accessibility permission.
README

hdiutil create -volname "TabSwipe" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_NAME" 2>/dev/null

rm -rf "$DMG_STAGING"

# --- Sign the DMG (Developer ID only) ---
if [ "$SIGN_MODE" = "developer-id" ]; then
    codesign --sign "$DEV_ID_CERT" --timestamp "$DMG_NAME"
    echo "✓ DMG signed with Developer ID"
fi

DMG_SIZE=$(du -h "$DMG_NAME" | cut -f1 | xargs)
echo "✓ Created $DMG_NAME ($DMG_SIZE)"

# --- Notarize and staple the DMG itself ---
# Second submission: the disk image is a separate artifact from the app and
# needs its own ticket, so Gatekeeper clears it at mount time.
NOTARIZED="skipped"
if [ "$NOTARY_READY" = "yes" ]; then
    echo ""
    echo "Notarizing $DMG_NAME..."
    if xcrun notarytool submit "$DMG_NAME" --keychain-profile "$NOTARIZE_PROFILE" --wait; then
        xcrun stapler staple "$DMG_NAME"
        xcrun stapler validate "$DMG_NAME"
        NOTARIZED="yes"
    else
        NOTARIZED="failed"
        echo "⚠ DMG notarization failed. For details:"
        echo "   xcrun notarytool submit $DMG_NAME --keychain-profile $NOTARIZE_PROFILE --wait --verbose"
    fi
fi

# --- Build the Sparkle update archive ---
# Sparkle downloads a zip, not the DMG: no mounting, and the app inside is
# already stapled. --sequesterRsrc preserves the symlinks a versioned framework
# needs, without which Sparkle.framework's signature fails to validate after
# the round trip.
echo ""
echo "Creating $ZIP_NAME (Sparkle update archive)..."
rm -f "$ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_NAME"

SIGN_UPDATE="$SCRATCH/artifacts/sparkle/Sparkle/bin/sign_update"
if [ -x "$SIGN_UPDATE" ]; then
    echo ""
    echo "Appcast entry — paste into czbz/tabswipe/appcast.xml:"
    echo "   version $VERSION, published $(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
    "$SIGN_UPDATE" "$ZIP_NAME" | sed 's/^/   /'
else
    echo "⚠ sign_update not found; cannot sign the update archive."
fi

# --- Verify what Gatekeeper will actually see ---
if [ "$SIGN_MODE" = "developer-id" ]; then
    echo ""
    echo "Verification:"
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 | sed 's/^/   /'
    spctl -a -t exec -vvv "$APP_BUNDLE" 2>&1 | sed 's/^/   /' || true
fi

# --- Summary ---
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ "$SIGN_MODE" = "developer-id" ] && [ "$NOTARIZED" = "yes" ] && [ "$APP_NOTARIZED" = "yes" ]; then
    echo "  🎉 Ready for distribution!"
    echo ""
    echo "  Both the app and the disk image are notarized and stapled."
    echo "  Send $DMG_NAME to anyone - they double-click to open, drag"
    echo "  TabSwipe to Applications, no warnings, no terminal, works offline."
elif [ "$SIGN_MODE" = "developer-id" ] && [ "$NOTARIZED" = "yes" ]; then
    echo "  DMG notarized, but the app bundle was not stapled."
    echo "  Users on a machine with no network may still see a warning."
elif [ "$SIGN_MODE" = "developer-id" ]; then
    echo "  Signed with Developer ID, but not notarized."
    echo "  Recipients will see a Gatekeeper warning until notarization runs."
else
    echo "  For yourself:"
    echo "    cp -R $APP_BUNDLE /Applications/"
    echo ""
    echo "  For friends (with $SIGN_MODE signing):"
    echo "    They'll need to right-click > Open on first launch."
fi
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
