import Cocoa
import ServiceManagement
import Sparkle
import TabSwipeCore

// MARK: - App Entry Point

@main
struct TabSwipeApp {
    // Static to ensure ARC doesn't release it (NSApplication.delegate is weak)
    static let delegate = AppDelegate()

    static func main() {
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
    /// the last three are created by Sparkle rendering release notes in a
    /// WebView, and did not exist before it was added.
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
        ].map { library.appendingPathComponent($0) }
    }

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var accessibilityCheckTimer: Timer?

    /// Sparkle. The check interval and feed URL live in Info.plist; this only
    /// has to exist and be started. Held strongly for the process lifetime —
    /// releasing it stops the scheduled checks.
    private var updaterController: SPUStandardUpdaterController!

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
        engine.applySettings(AppSettings.shared)
        engine.start()

        checkAccessibilityPermission()
        showSetupTipsIfNeeded()

        Log.info("TabSwipe started. Swipe distance: \(AppSettings.shared.swipeLevel), Direction: \(AppSettings.shared.direction)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        GestureEngine.shared.stop()
        Log.info("TabSwipe terminated")
    }

    // Relaunching the app (e.g. from Applications) restores a hidden icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem.isVisible = true
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
                Log.info("Accessibility permission granted — restarting gesture engine")
                GestureEngine.shared.restart()
            }
        }
    }

    private func showSetupTipsIfNeeded() {
        guard !AppSettings.shared.hasShownSetupTips else { return }
        AppSettings.shared.hasShownSetupTips = true

        let alert = NSAlert()
        alert.messageText = "One-Time Trackpad Setup"
        alert.informativeText = """
            macOS also uses 3-finger swipes for Mission Control and switching \
            full-screen apps. For clean tab switching, set those to four fingers:

            System Settings → Trackpad → More Gestures → set "Swipe between \
            full-screen applications" and "Mission Control" to Four Fingers.

            If you use three-finger drag (Accessibility → Pointer Control), \
            consider turning it off — it conflicts with this gesture.
            """
        alert.addButton(withTitle: "Open Trackpad Settings")
        alert.addButton(withTitle: "Done")

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = threeFingerIcon()
            button.toolTip = "TabSwipe"
        }
    }

    private func threeFingerIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()

            let fingerWidth: CGFloat = 3.2
            let fingerRadius: CGFloat = fingerWidth / 2
            let gap: CGFloat = 1.6
            let totalWidth = 3 * fingerWidth + 2 * gap
            let startX = (rect.width - totalWidth) / 2
            let heights: [CGFloat] = [10, 12, 10]
            let bottomY: CGFloat = 2.5

            for i in 0..<3 {
                let x = startX + CGFloat(i) * (fingerWidth + gap)
                let h = heights[i]
                let y = bottomY + (12 - h) / 2
                let fingerRect = NSRect(x: x, y: y, width: fingerWidth, height: h)
                NSBezierPath(roundedRect: fingerRect, xRadius: fingerRadius, yRadius: fingerRadius).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Menu

    private func buildMenu() {
        menu = NSMenu()
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
        let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = settings.isEnabled ? .on : .off
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
        let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
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
        GestureEngine.shared.applySettings(AppSettings.shared)
    }

    @objc private func setSwipeDistance(_ sender: NSMenuItem) {
        AppSettings.shared.swipeLevel = sender.tag
        GestureEngine.shared.applySettings(AppSettings.shared)
    }

    @objc private func setDirection(_ sender: NSMenuItem) {
        guard let direction = sender.representedObject as? String else { return }
        AppSettings.shared.direction = direction
        GestureEngine.shared.applySettings(AppSettings.shared)
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
