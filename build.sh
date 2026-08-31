#!/bin/bash
set -e

cd "$(dirname "$0")"

APP_NAME="TabSwipe"
APP_BUNDLE="$APP_NAME.app"
DMG_NAME="$APP_NAME.dmg"
TEAM_ID="GFJX8GLA7X"
NOTARIZE_PROFILE="TabSwipe-Notarize"

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

cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
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
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
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
</dict>
</plist>
PLIST

echo "Architectures in the built binary:"
lipo -archs "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | sed 's/^/   /'

# --- Sign the app ---
# Prefer Developer ID Application certificate (for distribution)
# Fall back to self-signed cert (for local dev)
DEV_ID_CERT=$(security find-identity -v -p codesigning | grep "Developer ID Application" | grep "$TEAM_ID" | head -1 | awk -F'"' '{print $2}')

if [ -n "$DEV_ID_CERT" ]; then
    echo "Signing with: $DEV_ID_CERT"

    # No entitlements needed: plain Swift/AppKit app, no JIT
    codesign --force --options runtime --timestamp \
        --sign "$DEV_ID_CERT" \
        "$APP_BUNDLE"

    SIGN_MODE="developer-id"
    echo "✓ Signed with Developer ID + hardened runtime"
elif security find-identity -v -p codesigning | grep -q "TabSwipe Signing"; then
    codesign --sign "TabSwipe Signing" --force "$APP_BUNDLE"
    SIGN_MODE="self-signed"
    echo "✓ Signed with self-signed cert (for local use only)"
else
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
  Quit TabSwipe from the menu bar icon, then drag
  TabSwipe.app from Applications to the Trash.
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
