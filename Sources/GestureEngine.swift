import Cocoa
import ApplicationServices
import os

// Wiring between the private multitouch framework and Chrome:
//
//   trackpad ──MT callback thread──▶ SwipeDetector ──▶ Ctrl(+Shift)+Tab
//                                    (under lock)       posted to Chrome's pid
//
// Touch frames arrive on a framework-owned background thread, so all mutable
// state lives behind one unfair lock and nothing slow ever runs under it.
// The main thread only touches this file through GestureEngine (device
// lifecycle, settings) and the NSWorkspace observers (frontmost-app cache).

private let chromeBundleID = "com.google.Chrome"

/// The Tab key. Ctrl+Tab / Ctrl+Shift+Tab are Chrome's browser-reserved
/// tab-cycling shortcuts — unlike Cmd+Opt+Arrow, web pages (Google Docs,
/// code editors) can never capture them.
private let kTabKey: UInt16 = 48

// MARK: - Thread-safe State (accessed from the MultitouchSupport callback thread)

private struct CallbackState {
    var detector = SwipeDetector()
    var chromePid: pid_t?  // non-nil only while Chrome is frontmost
}

private let stateLock = OSAllocatedUnfairLock(initialState: CallbackState())
private let eventSource = CGEventSource(stateID: .hidSystemState)

// MARK: - Keystroke Posting

private func postTabSwitch(_ event: SwipeEvent, to pid: pid_t) {
    // Without the Accessibility grant, posted events are silently dropped by
    // macOS anyway — checking here keeps the failure observable at one spot.
    guard AXIsProcessTrusted() else { return }
    guard let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: kTabKey, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: kTabKey, keyDown: false)
    else { return }

    var flags: CGEventFlags = .maskControl
    if event == .previous { flags.insert(.maskShift) }
    keyDown.flags = flags
    keyUp.flags = flags

    // Post directly to Chrome's pid rather than the system HID stream:
    // the keystroke can only ever reach Chrome, even if the user switches
    // apps between gesture detection and delivery.
    keyDown.postToPid(pid)
    keyUp.postToPid(pid)
}

// MARK: - Touch Callback

/// Runs on MultitouchSupport's background thread for every contact frame
/// (~90 Hz while touching). Summarizes the frame, runs the detector under
/// the lock, and posts any resulting keystroke after releasing it.
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

/// Owns the device lifecycle and feeds settings into the detector.
/// Main-thread only (asserted); the touch callback above is the sole
/// background-thread entry point.
public final class GestureEngine {
    public static let shared = GestureEngine()

    private let mt = MTFramework.shared
    // MTDeviceCreateList's array owns the MTDeviceRefs (CF Create rule);
    // holding it here is what keeps the raw pointers in `devices` alive.
    private var deviceList: CFArray?
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
