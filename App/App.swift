import Cocoa
import ServiceManagement
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
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var accessibilityCheckTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Actions

    @objc private func openAccessibilitySettings(_ sender: NSMenuItem) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
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
