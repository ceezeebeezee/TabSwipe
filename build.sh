#!/bin/bash
set -e

cd "$(dirname "$0")"

# Single source of truth for the release version. Sparkle compares this against
# the appcast to decide whether an update exists, so bumping it here is what
# makes a build "new" to everyone already running TabSwipe.
VERSION="1.5"

APP_NAME="TabSwipe"
APP_BUNDLE="$APP_NAME.app"
PKG_NAME="$APP_NAME.pkg"            # what people download and install
ZIP_NAME="$APP_NAME-$VERSION.zip"   # what Sparkle downloads for updates
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

# swiftc bakes in an LC_RPATH into the Command Line Tools' Swift libs
# (/Library/Developer/CommandLineTools/.../swift-*/macosx). On our macOS 13+
# deployment target the Swift runtime ships in the OS at /usr/lib/swift, so
# that dev-toolchain path is dead weight in a shipped binary — strip it. Match
# dynamically because the swift-x.y version in the path moves with the toolchain.
otool -l "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    | awk '/LC_RPATH/{c=2} c&&/ path /{print $2; c=0}' \
    | grep '/Library/Developer/CommandLineTools' \
    | while read -r rp; do
        install_name_tool -delete_rpath "$rp" "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null
    done

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
    <!-- Check automatically (weekly, per SUScheduledCheckInterval) without
         asking first — users are enrolled by default. Installing an update
         still requires a click: SUAllowsAutomaticUpdates is false below. -->
    <key>SUEnableAutomaticChecks</key>
    <true/>
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
    <!-- Sign the update feed itself, not just the payload. Without this a
         czbz.ai compromise could serve tampered release-notes HTML (rendered
         in a WebView) and altered version metadata; with it, the appcast and
         release notes must carry a valid EdDSA signature or the update is
         refused. SUVerifyUpdateBeforeExtraction is a required companion.
         Publish with generate_appcast, which signs the feed automatically. -->
    <key>SURequireSignedFeed</key>
    <true/>
    <key>SUVerifyUpdateBeforeExtraction</key>
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
        echo "  If they were there a moment ago, the login keychain is probably locked"
        echo "  (locked screen, sleep) — unlock the Mac and run again."
        # An unnotarized package is one that Gatekeeper rejects for every
        # downloader, and nothing else in this script or the publishing steps
        # would notice. Refuse to produce one unless explicitly told to.
        if [ "${ALLOW_UNNOTARIZED:-}" != "1" ]; then
            echo ""
            echo "✗ Refusing to build an unnotarized release. Set ALLOW_UNNOTARIZED=1 for a local test build."
            exit 1
        fi
    fi
fi

# --- Notarize the app, then staple the ticket INTO the bundle ---
# Stapling only the installer leaves the app unverifiable offline once it has
# been installed: the ticket would live on the package, not in the thing the
# user actually runs. Notarizing a zip of the bundle lets us staple the ticket
# into TabSwipe.app itself, before it is packaged — and the same stapled bundle
# is what Sparkle later ships as an update.
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

# --- Build the installer package ---
# Ships instead of a disk image. Installer.app does the placing, so there is
# nothing to drag and nothing to explain, and a package does not set the
# quarantine flag on what it installs — so the app never shows Gatekeeper's
# "downloaded from the Internet" confirmation on first launch either.
echo ""
echo "Creating $PKG_NAME..."
PKG_SCRIPTS="/tmp/TabSwipe-pkgscripts"
COMPONENT_PKG="/tmp/TabSwipe-component.pkg"
rm -rf "$PKG_SCRIPTS" "$PKG_NAME" "$COMPONENT_PKG"
mkdir -p "$PKG_SCRIPTS"

# Launch after installing, or a menu bar app with no Dock icon leaves the user
# staring at a "success" sheet with no evidence anything happened.
cat > "$PKG_SCRIPTS/postinstall" << 'POST'
#!/bin/bash
# The installer runs as root. Opening the app from here without dropping back
# to the console user would run TabSwipe as root: its preferences would land in
# root's home, and its login item and Accessibility grant would be recorded
# against the wrong user.
CONSOLE_USER=$(/usr/bin/stat -f "%Su" /dev/console)
if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
    CONSOLE_UID=$(/usr/bin/id -u "$CONSOLE_USER")
    /bin/launchctl asuser "$CONSOLE_UID" \
        /usr/bin/open -a "/Applications/TabSwipe.app" || true
fi
exit 0
POST
chmod +x "$PKG_SCRIPTS/postinstall"

# pkgbuild defaults to BundleIsRelocatable=true: Installer asks LaunchServices
# for an existing copy of the bundle and "updates" it wherever it lives — a dev
# checkout, the Trash, anywhere — instead of installing to /Applications. That
# is exactly wrong for us (uninstall + reinstall found a stray copy and put the
# app there, so nothing landed in /Applications and postinstall opened air).
# --analyze only works on a --root, so stage the app alone, generate the
# component plist, force the flag off, and build from that root.
PKG_ROOT="/tmp/TabSwipe-pkgroot"
COMPONENT_PLIST="/tmp/TabSwipe-component.plist"
rm -rf "$PKG_ROOT" "$COMPONENT_PLIST"
mkdir -p "$PKG_ROOT"
ditto "$APP_BUNDLE" "$PKG_ROOT/$APP_BUNDLE"

pkgbuild --analyze --root "$PKG_ROOT" "$COMPONENT_PLIST" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$COMPONENT_PLIST"

pkgbuild --root "$PKG_ROOT" \
         --component-plist "$COMPONENT_PLIST" \
         --scripts "$PKG_SCRIPTS" \
         --identifier "com.tabswipe.app.pkg" \
         --version "$VERSION" \
         --install-location "/Applications" \
         "$COMPONENT_PKG" >/dev/null
rm -rf "$PKG_ROOT" "$COMPONENT_PLIST"

# Packages are signed with productsign/productbuild and a Developer ID
# *Installer* identity — a different certificate from the Application one used
# for codesign above. Without it the package still builds and installs locally,
# but Gatekeeper will refuse it on anyone else's Mac.
INSTALLER_CERT=$(security find-identity -v | grep "Developer ID Installer" | grep "$TEAM_ID" | head -1 | awk -F'"' '{print $2}')

if [ -n "$INSTALLER_CERT" ]; then
    productbuild --package "$COMPONENT_PKG" --sign "$INSTALLER_CERT" --timestamp "$PKG_NAME" >/dev/null
    PKG_SIGNED="yes"
    echo "✓ Package signed with: $INSTALLER_CERT"
else
    productbuild --package "$COMPONENT_PKG" "$PKG_NAME" >/dev/null
    PKG_SIGNED="no"
    echo "⚠ No Developer ID Installer certificate found — package is UNSIGNED."
    echo "  It installs on this Mac but Gatekeeper will reject it elsewhere."
    echo "  Create one at developer.apple.com (Certificates → + → Developer ID"
    echo "  → Developer ID Installer), then re-run this script."
fi
rm -rf "$PKG_SCRIPTS" "$COMPONENT_PKG"

PKG_SIZE=$(du -h "$PKG_NAME" | cut -f1 | xargs)
echo "✓ Created $PKG_NAME ($PKG_SIZE)"

# --- Notarize and staple the package ---
# Its own submission: the package is a separate artifact from the app inside it
# and needs its own ticket so Gatekeeper clears it when it is opened.
NOTARIZED="skipped"
if [ "$NOTARY_READY" = "yes" ] && [ "$PKG_SIGNED" = "yes" ]; then
    echo ""
    echo "Notarizing $PKG_NAME..."
    if xcrun notarytool submit "$PKG_NAME" --keychain-profile "$NOTARIZE_PROFILE" --wait; then
        xcrun stapler staple "$PKG_NAME"
        xcrun stapler validate "$PKG_NAME"
        NOTARIZED="yes"
    else
        NOTARIZED="failed"
        echo "⚠ Package notarization failed. For details:"
        echo "   xcrun notarytool submit $PKG_NAME --keychain-profile $NOTARIZE_PROFILE --wait --verbose"
    fi
elif [ "$PKG_SIGNED" = "no" ]; then
    echo "  Skipping notarization: an unsigned package cannot be notarized."
fi

# --- Build the Sparkle update archive ---
# Sparkle downloads a zip, not the installer: updates replace the bundle in
# place rather than reinstalling, and the app inside is already stapled.
# --sequesterRsrc preserves the symlinks a versioned framework
# needs, without which Sparkle.framework's signature fails to validate after
# the round trip.
echo ""
echo "Creating $ZIP_NAME (Sparkle update archive)..."
rm -f "$ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_NAME"

# --- Generate the SIGNED appcast ---
# The app sets SURequireSignedFeed, so a hand-pasted enclosure signature is no
# longer enough: the feed and release notes must be signed too. generate_appcast
# does all of it — it reads SURequireSignedFeed from the app inside the zip and
# signs the appcast + embedded release notes with the same EdDSA key. It writes
# appcast.xml into its input directory, so stage the zip alone in dist/.
GENERATE_APPCAST="$SCRATCH/artifacts/sparkle/Sparkle/bin/generate_appcast"
DIST="dist"
if [ -x "$GENERATE_APPCAST" ]; then
    echo ""
    echo "Generating signed appcast..."
    rm -rf "$DIST"
    mkdir -p "$DIST"
    cp "$ZIP_NAME" "$DIST/"
    # Release notes: same basename as the zip, embedded as CDATA (no <body>).
    if [ -f "release-notes/$VERSION.html" ]; then
        cp "release-notes/$VERSION.html" "$DIST/${APP_NAME}-${VERSION}.html"
    fi
    "$GENERATE_APPCAST" \
        --download-url-prefix "https://czbz.ai/tabswipe/" \
        --embed-release-notes \
        --link "https://czbz.ai/tabswipe" \
        -o "$DIST/appcast.xml" \
        "$DIST"
    echo "✓ Signed appcast at $DIST/appcast.xml"
    echo "  Publish: copy $DIST/appcast.xml, $ZIP_NAME and $PKG_NAME to"
    echo "  czbz/tabswipe/, then deploy."
else
    echo "⚠ generate_appcast not found; cannot produce a signed appcast."
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
    echo "  Both the app and the installer are notarized and stapled."
    echo "  Send $PKG_NAME to anyone - they open it, click through, and"
    echo "  TabSwipe installs and launches itself. No dragging, and no"
    echo "  \"downloaded from the Internet\" warning: an installed package"
    echo "  is not quarantined."
elif [ "$SIGN_MODE" = "developer-id" ] && [ "$NOTARIZED" = "yes" ]; then
    echo "  Installer notarized, but the app bundle was not stapled."
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
