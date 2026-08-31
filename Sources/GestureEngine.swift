import Cocoa
import ApplicationServices
import os

private let chromeBundleID = "com.google.Chrome"
private let kTabKey: UInt16 = 48  // Ctrl+Tab / Ctrl+Shift+Tab: Chrome tab cycling, immune to page capture

// MARK: - Thread-safe State (accessed from the MultitouchSupport callback thread)

private struct CallbackState {
    var detector = SwipeDetector()
    var chromePid: pid_t?  // non-nil only while Chrome is frontmost
}

private let stateLock = OSAllocatedUnfairLock(initialState: CallbackState())
private let eventSource = CGEventSource(stateID: .hidSystemState)

// MARK: - Keystroke Posting

private func postTabSwitch(_ event: SwipeEvent, to pid: pid_t) {
    guard AXIsProcessTrusted() else { return }
    guard let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: kTabKey, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: kTabKey, keyDown: false)
    else { return }

    var flags: CGEventFlags = .maskControl
    if event == .previous { flags.insert(.maskShift) }
    keyDown.flags = flags
    keyUp.flags = flags

    // Post directly to Chrome's pid: no frontmost race, can't leak into other apps.
    keyDown.postToPid(pid)
    keyUp.postToPid(pid)
}

// MARK: - Touch Callback

private let touchCallback: MTContactCallback = { _, rawTouches, count, timestamp, _ in
    let n = Int(count)
    let touches = rawTouches.bindMemory(to: MTTouch.self, capacity: n)

    var active = 0
    var xSum: Float = 0
    var ySum: Float = 0
    for i in 0..<n {
        let touch = touches[i]
        // Sanity check: normalized positions must be near [0, 1]. Wildly
        // out-of-range values mean the MTTouch layout drifted in a macOS
        // update — drop the frame AND any in-progress gesture.
        let x = touch.normalized.pos.x
        let y = touch.normalized.pos.y
        if x < -0.5 || x > 1.5 || y < -0.5 || y > 1.5 {
            stateLock.withLock { $0.detector.reset() }
            return
        }
        if touch.state == 4 {
            active += 1
            xSum += x
            ySum += y
        }
    }

    let touchCount = active
    let avgX = touchCount > 0 ? xSum / Float(touchCount) : 0
    let avgY = touchCount > 0 ? ySum / Float(touchCount) : 0

    let fire: (SwipeEvent, pid_t)? = stateLock.withLock { state in
        guard let event = state.detector.process(touchCount: touchCount, avgX: avgX, avgY: avgY, timestamp: timestamp),
              let pid = state.chromePid
        else { return nil }
        return (event, pid)
    }
    if let (event, pid) = fire {
        postTabSwitch(event, to: pid)
    }
}

// MARK: - GestureEngine

public final class GestureEngine {
    public static let shared = GestureEngine()

    private let mt = MTFramework.shared
    private var deviceList: CFArray?  // owns the MTDeviceRefs; must outlive them
    private var devices: [MTDeviceRef] = []
    private var isRunning = false
    private var observers: [NSObjectProtocol] = []

    /// False when the private framework failed to load — gestures unavailable.
    public var isAvailable: Bool { mt != nil }

    init() {}

    public func start() {
        assert(Thread.isMainThread, "GestureEngine.start() must be called on the main thread")
        guard !isRunning else { return }

        let os = ProcessInfo.processInfo.operatingSystemVersion
        Log.info("macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), MTTouch size: \(MemoryLayout<MTTouch>.size) bytes")

        updateChromePid(NSWorkspace.shared.frontmostApplication)
        installObservers()
        attachDevices()
        isRunning = true
    }

    public func stop() {
        assert(Thread.isMainThread, "GestureEngine.stop() must be called on the main thread")
        guard isRunning else { return }
        removeObservers()
        detachDevices()
        isRunning = false
        Log.info("Gesture engine stopped")
    }

    /// Full restart: re-enumerates trackpads. Used after wake and after the
    /// Accessibility grant (TCC can gate multitouch delivery until granted).
    public func restart() {
        stop()
        start()
    }

    // MARK: Devices

    private func attachDevices() {
        guard let mt else {
            Log.error("MultitouchSupport unavailable — gestures disabled")
            return
        }
        guard let list = mt.createDeviceList() else {
            Log.error("MTDeviceCreateList returned nil")
            return
        }
        deviceList = list

        let count = CFArrayGetCount(list)
        guard count > 0 else {
            Log.error("No multitouch devices found")
            return
        }
        for i in 0..<count {
            let device = UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(list, i)!)
            mt.registerContactFrameCallback(device, touchCallback)
            let status = mt.deviceStart(device, 0)
            if status != 0 {
                Log.error("MTDeviceStart failed with status \(status) for device \(i)")
            }
            devices.append(device)
        }
        Log.info("Gesture engine active on \(count) multitouch device(s)")
    }

    private func detachDevices() {
        guard let mt else { return }
        for device in devices {
            mt.deviceStop(device)
            mt.unregisterContactFrameCallback?(device, touchCallback)
        }
        devices.removeAll()
        deviceList = nil
    }

    // MARK: Observers

    private func installObservers() {
        let center = NSWorkspace.shared.notificationCenter

        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.updateChromePid(app)
        })

        // MultitouchSupport callbacks are known to die across sleep/wake.
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Log.info("Woke from sleep — re-attaching trackpad devices")
            self?.detachDevices()
            self?.attachDevices()
        })
    }

    private func removeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }

    private func updateChromePid(_ app: NSRunningApplication?) {
        let pid: pid_t? = app?.bundleIdentifier == chromeBundleID ? app?.processIdentifier : nil
        stateLock.withLock { $0.chromePid = pid }
    }

    // MARK: Settings

    public func applySettings(_ settings: AppSettings) {
        apply(enabled: settings.isEnabled, swipeLevel: settings.swipeLevel, direction: settings.direction)
    }

    public func apply(enabled: Bool, swipeLevel: Int, direction: String) {
        let threshold = thresholdForLevel(swipeLevel)
        let multiplier: Float = direction == "LTR" ? 1.0 : -1.0

        stateLock.withLock { state in
            state.detector.isEnabled = enabled
            state.detector.threshold = threshold
            state.detector.directionMultiplier = multiplier
        }
    }

    // Expose state for testing
    public var currentThreshold: Float {
        stateLock.withLock { $0.detector.threshold }
    }
    public var currentDirectionMultiplier: Float {
        stateLock.withLock { $0.detector.directionMultiplier }
    }
    public var currentEnabled: Bool {
        stateLock.withLock { $0.detector.isEnabled }
    }
}
