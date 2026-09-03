import Cocoa
import ServiceManagement
import LetsMove
import Sparkle
import TabSwipeCore

// MARK: - App Entry Point

@main
struct TabSwipeApp {
    // Static to ensure ARC doesn't release it (NSApplication.delegate is weak)
    static let delegate = AppDelegate()

    static func main() {
        // macOS 26 decorates menu items it recognises with its own symbols —
        // "About" picks up an ⓘ. There is a global switch for this, but that
        // is the user's setting to make, not ours. Writing it into the
        // argument domain instead scopes it to this process: highest priority,
        // in memory only, nothing left behind in anyone's preferences.
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["NSMenuEnableActionImages"] = false
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)

        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

// MARK: - AppDelegate

/// All UI: the menu bar item, its menu (rebuilt fresh on every open so it
/// always reflects live permission/settings state), and the two one-time
/// onboarding flows — the Accessibility grant and the trackpad-gesture tip.
class AppDelegate: NSObject, NSApplicationDelegate {
    static let websiteURL = URL(string: "https://czbz.ai/tabswipe")
    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

    /// Everything TabSwipe leaves outside its own bundle. Kept in one place so
    /// Uninstall cannot drift out of sync with what actually accumulates —
    /// the Caches/HTTPStorages/WebKit trio is created by Sparkle rendering
    /// release notes in a WebView, and Logs only exists if Debug Logging was
    /// ever turned on.
    private static var supportFileURLs: [URL] {
        guard
            let id = Bundle.main.bundleIdentifier,
            let library = try? FileManager.default.url(
                for: .libraryDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false)
        else { return [] }

        return [
            "Preferences/\(id).plist",
            "Saved Application State/\(id).savedState",
            "Caches/\(id)",
            "HTTPStorages/\(id)",
            "WebKit/\(id)",
        ].map { library.appendingPathComponent($0) } + [Log.logDirectoryURL]
    }

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var accessibilityCheckTimer: Timer?

    /// Sparkle. The check interval and feed URL live in Info.plist; this only
    /// has to exist and be started. Held strongly for the process lifetime —
    /// releasing it stops the scheduled checks.
    private var updaterController: SPUStandardUpdaterController!

    func applicationWillFinishLaunching(_ notification: Notification) {
        // First run: offer to move into /Applications and relaunch from there.
        // Must precede the menu bar and the Accessibility prompt — macOS keys
        // the Accessibility grant to the bundle's location, so granting it to a
        // copy that is about to move would waste the grant. If the user accepts,
        // LetsMove relaunches the moved copy and terminates this process.
        // (LetsMove handles the copy, the quarantine flag, and the relaunch;
        // its shell relaunch shell-quotes the path, and a colliding target is
        // moved to the Trash rather than deleted.)
        PFMoveToApplicationsFolderIfNecessary()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before the menu is built: the Check for Updates item targets it.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        setupStatusItem()
        buildMenu()

        let engine = GestureEngine.shared
        // Before start(), so that device attachment is in the debug log.
        engine.setDebugLogging(AppSettings.shared.debugLogging)
        engine.applySettings(AppSettings.shared)
        engine.start()

        checkAccessibilityPermission()
        showSetupTipsIfNeeded()

        Log.notice("TabSwipe started. Swipe distance: \(AppSettings.shared.swipeLevel), Direction: \(AppSettings.shared.direction)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        GestureEngine.shared.stop()
        Log.notice("TabSwipe terminated")
    }

    // Relaunching the app (e.g. from Applications) restores a hidden icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // statusItem is nil until applicationDidFinishLaunching; a reopen can
        // arrive during the first-run move dialog before then.
        statusItem?.isVisible = true
        return false
    }

    // MARK: - Permissions

    private func checkAccessibilityPermission() {
        // Accessibility is needed to post keystrokes; on modern macOS it also
        // gates multitouch event delivery, so restart the engine once granted.
        guard !AXIsProcessTrusted() else { return }

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
        Log.info("Accessibility permission requested via system prompt")

        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] timer in
            if AXIsProcessTrusted() {
                timer.invalidate()
                self?.accessibilityCheckTimer = nil
                Log.notice("Accessibility permission granted — restarting gesture engine")
                GestureEngine.shared.restart()
            }
        }
    }

    /// Registers TabSwipe as a login item, once, on first run. Returns whether
    /// it will actually start with the Mac, so the welcome text can say so only
    /// when it is true.
    ///
    /// Only from an Applications folder. A login item records the path it was
    /// registered from, so doing this while still running out of a download or
    /// a disk image would enrol a bundle that is about to vanish, and macOS
    /// keeps showing the dead entry in System Settings afterwards.
    @discardableResult
    private func startAtLoginOnFirstRun() -> Bool {
        let path = Bundle.main.bundleURL.path
        let installed = ["/Applications", NSHomeDirectory() + "/Applications"]
            .contains { path.hasPrefix($0 + "/") }
        guard installed else {
            Log.info("Not registering a login item: running from \(path)")
            return false
        }

        switch SMAppService.mainApp.status {
        case .enabled:
            return true
        case .requiresApproval:
            // Turned off in System Settings at some point. Re-registering
            // cannot override that, and should not try to.
            Log.info("Login item requires approval in System Settings")
            return false
        default:
            do {
                try SMAppService.mainApp.register()
                Log.info("Registered as a login item")
                return true
            } catch {
                Log.error("Could not register login item: \(error)")
                return false
            }
        }
    }

    private func showSetupTipsIfNeeded() {
        guard !AppSettings.shared.hasShownSetupTips else { return }
        AppSettings.shared.hasShownSetupTips = true

        let startsAtLogin = startAtLoginOnFirstRun()

        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "TabSwipe is running"
        alert.informativeText =
            "It lives in your menu bar. There is no window — the icon up there is the whole interface."
        alert.accessoryView = Self.welcomeAccessoryView(startsAtLogin: startsAtLogin)
        alert.addButton(withTitle: "Open Trackpad Settings")
        alert.addButton(withTitle: "Done")

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The body of the welcome dialog. NSAlert only offers two flat strings, so
    /// anything with structure has to be an accessory view.
    private static func welcomeAccessoryView(startsAtLogin: Bool) -> NSView {
        let width: CGFloat = 380
        let body = NSMutableAttributedString()

        let titleStyle = NSMutableParagraphStyle()
        titleStyle.paragraphSpacingBefore = 14

        let textStyle = NSMutableParagraphStyle()
        textStyle.lineSpacing = 2

        func section(_ title: String, _ text: String) {
            if body.length == 0 { titleStyle.paragraphSpacingBefore = 0 }
            body.append(NSAttributedString(string: title + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: titleStyle.copy(),
            ]))
            titleStyle.paragraphSpacingBefore = 14
            body.append(NSAttributedString(string: text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: textStyle,
            ]))
        }

        section(
            "Swipe to switch tabs",
            "Three fingers left or right, anywhere on the trackpad, moves Chrome "
                + "one tab. Chrome does not need to be focused for the swipe to land."
        )

        section(
            "Give macOS four fingers",
            "macOS claims three-finger swipes for Mission Control and for moving "
                + "between full-screen apps, so until you change those, both fire at "
                + "once. Under More Gestures, set them to Four Fingers. Three-finger "
                + "drag, in Accessibility → Pointer Control, conflicts too."
        )

        section(
            "Tune it from the menu",
            "Swipe Distance sets how far your fingers travel per tab — 1 is a flick, "
                + "10 is a long drag. Direction picks which way counts as forward. "
                + "Enabled pauses the gesture without quitting."
        )

        section(
            startsAtLogin ? "Starts with your Mac" : "Starting with your Mac",
            startsAtLogin
                ? "TabSwipe has added itself to your login items, so it is back "
                    + "after a restart. Turn that off any time from the menu."
                : "Switch on Start at Login from the menu and TabSwipe will be "
                    + "back after a restart."
        )

        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = body
        label.isSelectable = false
        label.preferredMaxLayoutWidth = width

        // NSAlert insets its own two labels 8pt further in than it places an
        // accessory view, so the text is indented to match rather than sitting
        // proud of the title above it. The container keeps the full width —
        // widening it would make the alert itself wider and re-centre
        // everything.
        let leftInset: CGFloat = 4
        let textWidth = width - leftInset
        label.preferredMaxLayoutWidth = textWidth

        let height = label.sizeThatFits(
            NSSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        label.frame = NSRect(x: leftInset, y: 8, width: textWidth, height: height)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height + 8))
        container.addSubview(label)
        return container
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = threeFingerIcon()
            button.toolTip = "TabSwipe"
        }
    }

    /// The menu bar glyph: the same mark as the app icon and the website —
    /// three fingers with their bottoms aligned, the middle one reaching
    /// higher, over the trackpad they swipe across. Drawn as round-capped
    /// strokes rather than filled rectangles so it matches at this size.
    ///
    /// Template images are tinted from their alpha channel, which is what lets
    /// the fainter bar stay fainter in both light and dark menu bars.
    private func threeFingerIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            func stroke(from a: NSPoint, to b: NSPoint, width: CGFloat, alpha: CGFloat) {
                let path = NSBezierPath()
                path.move(to: a)
                path.line(to: b)
                path.lineWidth = width
                path.lineCapStyle = .round
                NSColor.black.withAlphaComponent(alpha).setStroke()
                path.stroke()
            }

            let bottom: CGFloat = 7.6
            stroke(from: NSPoint(x: 5.6, y: bottom), to: NSPoint(x: 5.6, y: 13.4), width: 2.4, alpha: 1)
            stroke(from: NSPoint(x: 9.0, y: bottom), to: NSPoint(x: 9.0, y: 15.4), width: 2.4, alpha: 1)
            stroke(from: NSPoint(x: 12.4, y: bottom), to: NSPoint(x: 12.4, y: 13.4), width: 2.4, alpha: 1)
            stroke(from: NSPoint(x: 3.4, y: 4.4), to: NSPoint(x: 14.6, y: 4.4), width: 1.8, alpha: 0.45)
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Menu

    private func buildMenu() {
        menu = NSMenu()
        // Without this every row is indented by the checkmark gutter, because
        // one item somewhere in the menu has state. The two items that need to
        // show state carry it in their titles instead. Submenus keep their own
        // state columns, so the tick still marks the chosen distance and
        // direction where a genuine choice is being made.
        menu.showsStateColumn = false
        menu.delegate = self
        statusItem.menu = menu
    }

    private func rebuildMenuItems() {
        menu.removeAllItems()

        let settings = AppSettings.shared

        // Warnings (rechecked every time the menu opens)
        if !GestureEngine.shared.isAvailable {
            menu.addItem(NSMenuItem(title: "⚠️ Trackpad gesture API unavailable", action: nil, keyEquivalent: ""))
            menu.addItem(.separator())
        }
        if !AXIsProcessTrusted() {
            let item = NSMenuItem(title: "⚠️ Grant Accessibility Access…",
                                  action: #selector(openAccessibilitySettings(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }

        // Enabled toggle
        let enabledItem = NSMenuItem(
            title: settings.isEnabled ? "Enabled ✓" : "Enabled",
            action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        enabledItem.target = self
        menu.addItem(enabledItem)

        menu.addItem(.separator())

        // Swipe distance submenu
        let distanceItem = NSMenuItem(title: "Swipe Distance: \(settings.swipeLevel)", action: nil, keyEquivalent: "")
        let distanceMenu = NSMenu()
        for level in 1...10 {
            var title = "\(level)"
            if level == 1 { title += " (shortest)" }
            else if level == 5 { title += " (medium)" }
            else if level == 10 { title += " (longest)" }

            let item = NSMenuItem(title: title, action: #selector(setSwipeDistance(_:)), keyEquivalent: "")
            item.target = self
            item.tag = level
            item.state = level == settings.swipeLevel ? .on : .off
            distanceMenu.addItem(item)
        }
        distanceItem.submenu = distanceMenu
        menu.addItem(distanceItem)

        // Direction submenu
        let directionItem = NSMenuItem(title: "Direction", action: nil, keyEquivalent: "")
        let directionMenu = NSMenu()

        for (title, value) in [
            ("Swipe Right → Next Tab", "RTL"),
            ("Swipe Left → Next Tab", "LTR")
        ] {
            let item = NSMenuItem(title: title, action: #selector(setDirection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = settings.direction == value ? .on : .off
            directionMenu.addItem(item)
        }

        directionItem.submenu = directionMenu
        menu.addItem(directionItem)

        menu.addItem(.separator())

        // Start at Login
        let startsAtLogin = SMAppService.mainApp.status == .enabled
        let loginItem = NSMenuItem(
            title: startsAtLogin ? "Start at Login ✓" : "Start at Login",
            action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        // Hide from Menu Bar (until relaunch)
        let hideItem = NSMenuItem(title: "Hide Until Relaunch", action: #selector(hideMenuBar(_:)), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)

        menu.addItem(.separator())

        // Check for Updates
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = self
        updateItem.isEnabled = updaterController.updater.canCheckForUpdates
        menu.addItem(updateItem)

        // About
        let aboutItem = NSMenuItem(title: "About TabSwipe", action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        // Troubleshooting submenu. Its items carry real state, so it keeps
        // its state column like the other submenus.
        let troubleshootingItem = NSMenuItem(title: "Troubleshooting", action: nil, keyEquivalent: "")
        let troubleshootingMenu = NSMenu()
        troubleshootingMenu.autoenablesItems = false

        let restartItem = NSMenuItem(title: "Restart Gesture Detection",
                                     action: #selector(restartGestureDetection(_:)), keyEquivalent: "")
        restartItem.target = self
        troubleshootingMenu.addItem(restartItem)

        troubleshootingMenu.addItem(.separator())

        let debugItem = NSMenuItem(title: "Debug Logging",
                                   action: #selector(toggleDebugLogging(_:)), keyEquivalent: "")
        debugItem.target = self
        debugItem.state = settings.debugLogging ? .on : .off
        troubleshootingMenu.addItem(debugItem)

        let showLogItem = NSMenuItem(title: "Show Debug Log in Finder",
                                     action: #selector(showDebugLog(_:)), keyEquivalent: "")
        showLogItem.target = self
        showLogItem.isEnabled = FileManager.default.fileExists(atPath: Log.logFileURL.path)
        troubleshootingMenu.addItem(showLogItem)

        troubleshootingItem.submenu = troubleshootingMenu
        menu.addItem(troubleshootingItem)

        // Uninstall
        let uninstallItem = NSMenuItem(title: "Uninstall TabSwipe…", action: #selector(uninstall(_:)), keyEquivalent: "")
        uninstallItem.target = self
        menu.addItem(uninstallItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Actions

    @objc private func openAccessibilitySettings(_ sender: NSMenuItem) {
        if let url = Self.accessibilitySettingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        AppSettings.shared.isEnabled.toggle()
        Log.notice("Menu: Enabled set to \(AppSettings.shared.isEnabled)")
        GestureEngine.shared.applySettings(AppSettings.shared)
    }

    @objc private func setSwipeDistance(_ sender: NSMenuItem) {
        AppSettings.shared.swipeLevel = sender.tag
        Log.notice("Menu: Swipe Distance set to \(sender.tag)")
        GestureEngine.shared.applySettings(AppSettings.shared)
    }

    @objc private func setDirection(_ sender: NSMenuItem) {
        guard let direction = sender.representedObject as? String else { return }
        AppSettings.shared.direction = direction
        Log.notice("Menu: Direction set to \(direction)")
        GestureEngine.shared.applySettings(AppSettings.shared)
    }

    // MARK: Troubleshooting

    @objc private func restartGestureDetection(_ sender: NSMenuItem) {
        Log.notice("Menu: Restart Gesture Detection")
        GestureEngine.shared.restart()
    }

    @objc private func toggleDebugLogging(_ sender: NSMenuItem) {
        let enabled = !AppSettings.shared.debugLogging
        AppSettings.shared.debugLogging = enabled
        GestureEngine.shared.setDebugLogging(enabled)
    }

    @objc private func showDebugLog(_ sender: NSMenuItem) {
        NSWorkspace.shared.activateFileViewerSelecting([Log.logFileURL])
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.error("Login item error: \(error)")
        }
    }

    @objc private func hideMenuBar(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Hide Menu Bar Icon?"
        alert.informativeText = "The app keeps running in the background.\n\nTo show the icon again, relaunch TabSwipe from Applications."
        alert.addButton(withTitle: "Hide")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            statusItem.isVisible = false
        }
    }

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        // Same reason as the About dialog: an LSUIElement app is not frontmost
        // when its menu is clicked, so Sparkle's window would open behind
        // whatever the user was looking at.
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(sender)
    }

    @objc private func showAbout(_ sender: NSMenuItem) {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let copyright = info?["NSHumanReadableCopyright"] as? String
            ?? "Copyright 2026 Caesar Sengupta"

        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "TabSwipe \(version)"
        alert.informativeText = """
            Swipe three fingers on your trackpad to move between Chrome tabs.

            By Caesar Sengupta
            \(copyright)
            """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Visit Website")

        // LSUIElement apps are not frontmost when their menu is clicked, so the
        // alert would otherwise open behind whatever the user was looking at.
        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertSecondButtonReturn, let url = Self.websiteURL {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func uninstall(_ sender: NSMenuItem) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Uninstall TabSwipe?"
        alert.informativeText = """
            This turns off Start at Login, deletes TabSwipe's settings, moves \
            the app to the Trash, and quits.

            Afterwards you will be shown how to remove TabSwipe's Accessibility \
            permission — the one part macOS does not allow an app to do for \
            itself.
            """
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[1].keyEquivalent = "\u{1b}"  // Esc cancels

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performUninstall()
    }

    /// The teardown itself, split from the confirmation so it can be exercised
    /// without a click. Safe to call only once — it ends in exit().
    func performUninstall() {
        // Order is not arbitrary. The login item has to go first, while the
        // bundle still exists: SMAppService identifies it by the app it points
        // at, so once that is in the Trash the registration cannot be undone
        // and System Settings is left with an entry the user can only clear by
        // resetting every app's login items.
        if SMAppService.mainApp.status == .enabled {
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                Log.error("Uninstall: could not unregister login item: \(error)")
            }
        }

        GestureEngine.shared.stop()

        // removePersistentDomain rather than just unlinking the plist: the
        // preferences daemon holds them in memory and would write them back
        // out over the deletion.
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        for url in Self.supportFileURLs {
            try? FileManager.default.removeItem(at: url)
        }

        // Trashing the bundle out from under the running process is allowed —
        // the executable stays mapped, so this alert and the one after it still
        // work. Async because recycle reports failure via its completion.
        let bundleURL = Bundle.main.bundleURL
        NSWorkspace.shared.recycle([bundleURL]) { [weak self] _, error in
            DispatchQueue.main.async {
                self?.finishUninstall(bundleURL: bundleURL, trashError: error)
            }
        }
    }

    private func finishUninstall(bundleURL: URL, trashError: Error?) {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage

        if let trashError {
            // Read-only volume, still on the disk image, or App Translocation.
            alert.alertStyle = .warning
            alert.messageText = "Settings removed — delete the app yourself"
            alert.informativeText = """
                The login item and TabSwipe's settings are gone, but the app \
                could not be moved to the Trash: \(trashError.localizedDescription)

                Drag TabSwipe to the Trash, then remove it under System Settings \
                › Privacy & Security › Accessibility.
                """
            alert.addButton(withTitle: "Show Me the App")
            alert.addButton(withTitle: "Quit")
        } else {
            alert.messageText = "TabSwipe is uninstalled"
            alert.informativeText = """
                The app is in the Trash and its settings are gone.

                One last step, which macOS only allows you to do: open Privacy & \
                Security › Accessibility, select TabSwipe, and click the minus \
                button to remove its leftover permission.
                """
            alert.addButton(withTitle: "Open Accessibility Settings")
            alert.addButton(withTitle: "Done")
        }

        if alert.runModal() == .alertFirstButtonReturn {
            if trashError != nil {
                NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
            } else if let url = Self.accessibilitySettingsURL {
                NSWorkspace.shared.open(url)
            }
        }

        // exit() rather than terminate(): the normal shutdown path would give
        // AppKit a chance to write window and status-item state back into the
        // defaults domain we just deleted.
        exit(0)
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Rebuild fresh each open — also rechecks permission/availability state
        rebuildMenuItems()
    }
}
