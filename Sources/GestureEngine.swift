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

    // Bookkeeping for the debug log and the heartbeat. Kept always — it is a
    // couple of stores per frame — but only read when Debug Logging is on.
    var frames: UInt64 = 0
    var lastFrameTime: CFAbsoluteTime = 0
    var lastFrameWasBad = false
}

private let stateLock = OSAllocatedUnfairLock(initialState: CallbackState())
private let eventSource = CGEventSource(stateID: .hidSystemState)

// MARK: - Keystroke Posting

/// Returns whether anything was posted; the reason for a false is logged.
private func postTabSwitch(_ event: SwipeEvent, to pid: pid_t) -> Bool {
    // Without the Accessibility grant, posted events are silently dropped by
    // macOS anyway — checking here keeps the failure observable at one spot.
    guard AXIsProcessTrusted() else {
        Log.debug("Swipe dropped: Accessibility permission is not granted")
        return false
    }
    guard let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: kTabKey, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: kTabKey, keyDown: false)
    else {
        Log.error("Could not create the keyboard events for a tab switch")
        return false
    }

    var flags: CGEventFlags = .maskControl
    if event == .previous { flags.insert(.maskShift) }
    keyDown.flags = flags
    keyUp.flags = flags

    // Post directly to Chrome's pid rather than the system HID stream:
    // the keystroke can only ever reach Chrome, even if the user switches
    // apps between gesture detection and delivery.
    keyDown.postToPid(pid)
    keyUp.postToPid(pid)
    return true
}

// MARK: - Touch Callback

/// Runs on MultitouchSupport's background thread for every contact frame
/// (~90 Hz while touching). Summarizes the frame, runs the detector under
/// the lock, and posts any resulting keystroke after releasing it.
///
/// Debug lines are collected while the lock is held and emitted after it is
/// released, so logging never extends the critical section.
private let touchCallback: MTContactCallback = { device, rawTouches, count, timestamp, _ in
    let n = Int(count)
    let touches = rawTouches.bindMemory(to: MTTouch.self, capacity: n)
    let debug = Log.isDebugEnabled

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
            let firstBad = stateLock.withLock { state -> Bool in
                state.detector.reset()
                let first = !state.lastFrameWasBad
                state.lastFrameWasBad = true
                return first
            }
            if firstBad {
                Log.error("Dropping touch frames with out-of-range positions (\(x), \(y)) — MTTouch layout may have changed")
            }
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
    let now = CFAbsoluteTimeGetCurrent()
    let deviceAddress = Int(bitPattern: device)

    struct Outcome {
        var fire: (event: SwipeEvent, pid: pid_t)?
        var armed = false
        var lines: [String] = []
    }
    let outcome: Outcome = stateLock.withLock { state in
        var out = Outcome()
        state.frames += 1
        state.lastFrameWasBad = false
        let gap = now - state.lastFrameTime
        state.lastFrameTime = now

        let wasTracking = state.detector.isTracking
        let wasSuppressed = state.detector.isSuppressed
        let event = state.detector.process(touchCount: touchCount, avgX: avgX, avgY: avgY, timestamp: timestamp)
        out.armed = state.detector.isTracking && !wasTracking

        if debug {
            if state.frames > 1, gap > 30 {
                out.lines.append("Touch frames resumed after \(Int(gap))s without any")
            }
            if out.armed {
                out.lines.append(String(format: "Three fingers down at (%.2f, %.2f) on %p, device time %.3f — tracking",
                                        avgX, avgY, deviceAddress, timestamp))
            }
            if state.detector.isSuppressed, !wasSuppressed {
                out.lines.append(touchCount > 3
                    ? "Gesture suppressed: \(touchCount) fingers — until every finger lifts"
                    : "Gesture suppressed: vertical movement (a system gesture) — until every finger lifts")
            }
            if touchCount == 0, wasTracking || wasSuppressed {
                out.lines.append("All fingers lifted")
            }
        }

        guard let event else { return out }
        guard let pid = state.chromePid else {
            if debug { out.lines.append("Swipe detected but Chrome is not the frontmost app — nothing sent") }
            return out
        }
        out.fire = (event, pid)
        return out
    }
    var lines = outcome.lines

    // The frontmost-app cache is refreshed every time a gesture starts, on
    // the main thread. By the time the fingers have travelled far enough to
    // fire, the answer is in place — and no missed activation notification
    // can leave swipes with nowhere to go for the rest of the session.
    if outcome.armed {
        DispatchQueue.main.async { GestureEngine.shared.refreshChromePid(source: "gesture start") }
    }

    if let (event, pid) = outcome.fire, postTabSwitch(event, to: pid), debug {
        lines.append("Swipe → \(event == .next ? "next" : "previous") tab: "
            + "Ctrl+\(event == .previous ? "Shift+" : "")Tab posted to Chrome (pid \(pid))")
    }
    for line in lines { Log.debug(line) }
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
    private var pendingReattach: [DispatchWorkItem] = []

    // Debug Logging: a once-a-minute line saying whether frames are flowing.
    private var heartbeat: Timer?
    private var heartbeatFrames: UInt64 = 0

    /// False when the private framework failed to load — gestures unavailable.
    public var isAvailable: Bool { mt != nil }

    init() {}

    public func start() {
        assert(Thread.isMainThread, "GestureEngine.start() must be called on the main thread")
        guard !isRunning else { return }

        updateChromePid(NSWorkspace.shared.frontmostApplication, source: "start")
        installObservers()
        attachDevices()
        isRunning = true
    }

    public func stop() {
        assert(Thread.isMainThread, "GestureEngine.stop() must be called on the main thread")
        guard isRunning else { return }
        cancelPendingReattach()
        removeObservers()
        detachDevices()
        isRunning = false
        Log.notice("Gesture engine stopped")
    }

    /// Full restart: re-enumerates trackpads. Used by Troubleshooting ›
    /// Restart Gesture Detection and after the Accessibility grant (TCC can
    /// gate multitouch delivery until granted).
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
            } else if let isRunning = mt.deviceIsRunning, !isRunning(device) {
                Log.error("MTDeviceStart returned success but device \(i) reports it is not running")
            }
            devices.append(device)
            Log.debug("Device \(i): \(mt.describe(device))")
        }
        Log.notice("Gesture engine active on \(count) multitouch device(s)")
    }

    private func detachDevices() {
        guard let mt else { return }
        for device in devices {
            mt.deviceStop(device)
            mt.unregisterContactFrameCallback?(device, touchCallback)
        }
        devices.removeAll()
        deviceList = nil
        // Whatever gesture was in flight died with the devices. Without this
        // a "suppressed until every finger lifts" from before a sleep would
        // wait for a lift frame that the old device will never deliver.
        stateLock.withLock { $0.detector.reset() }
    }

    // MARK: Observers

    private func installObservers() {
        let center = NSWorkspace.shared.notificationCenter

        func observe(_ name: Notification.Name, _ handler: @escaping (Notification) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main, using: handler))
        }

        observe(NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.updateChromePid(app, source: "activation")
        }

        // The wake notification can arrive before the trackpad has finished
        // re-enumerating. Re-attaching in that window binds to stale device
        // handles that never deliver a frame — and nothing reports an error,
        // so the menu bar icon stays up while gestures are silently dead. So:
        // re-attach after a short delay, and once more later as a safety net.
        // Both passes are idempotent (detach + attach) and cheap.
        observe(NSWorkspace.didWakeNotification) { [weak self] _ in
            Log.notice("Woke from sleep — scheduling trackpad re-attach")
            self?.scheduleReattach(after: "wake")
        }
        // Lid-open / display wake can bring the trackpad back on a different
        // path than a full system wake (clamshell sleep, external display).
        observe(NSWorkspace.screensDidWakeNotification) { [weak self] _ in
            Log.notice("Screens woke — scheduling trackpad re-attach")
            self?.scheduleReattach(after: "screen wake")
        }

        // The rest only mark time in the log, so a report of "it stopped
        // working" can be lined up against what the Mac was doing.
        observe(NSWorkspace.willSleepNotification) { _ in Log.notice("Going to sleep") }
        observe(NSWorkspace.screensDidSleepNotification) { _ in Log.notice("Screens slept") }
        observe(NSWorkspace.sessionDidResignActiveNotification) { _ in Log.notice("User session became inactive (fast user switch)") }
        observe(NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] _ in
            Log.notice("User session became active")
            self?.refreshChromePid(source: "session active")
        }
    }

    /// Re-attach the trackpad after a wake — twice. The first pass runs once
    /// the hardware has had a moment to re-enumerate; the second is a safety
    /// net in case the first still caught it mid-transition. A full wake posts
    /// both wake notifications within milliseconds, so a pending schedule is
    /// replaced rather than doubled.
    private func scheduleReattach(after reason: String) {
        cancelPendingReattach()
        pendingReattach = [2.0, 8.0].map { delay in
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isRunning else { return }
                Log.notice("Re-attaching trackpad devices (\(Int(delay))s after \(reason))")
                self.detachDevices()
                self.attachDevices()
                self.refreshChromePid(source: "re-attach")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    private func cancelPendingReattach() {
        pendingReattach.forEach { $0.cancel() }
        pendingReattach.removeAll()
    }

    private func removeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }

    // MARK: Chrome target

    /// Re-reads the frontmost app. The activation notification is the primary
    /// source, but not every route back to Chrome posts one — so this also
    /// runs after wake, on session activation, and whenever a gesture starts.
    public func refreshChromePid(source: String) {
        assert(Thread.isMainThread)
        updateChromePid(NSWorkspace.shared.frontmostApplication, source: source)
    }

    private func updateChromePid(_ app: NSRunningApplication?, source: String) {
        let pid: pid_t? = app?.bundleIdentifier == chromeBundleID ? app?.processIdentifier : nil
        let changed = stateLock.withLock { state -> Bool in
            let changed = state.chromePid != pid
            state.chromePid = pid
            return changed
        }
        if changed {
            Log.debug("Frontmost app: \(app?.bundleIdentifier ?? "none") (\(source)) — "
                + (pid.map { "swipes go to Chrome pid \($0)" } ?? "swipes have no target"))
        }
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
        Log.debug("Settings applied: enabled \(enabled), swipe distance \(swipeLevel) (threshold \(threshold)), direction \(direction)")
    }

    // MARK: Debug Logging

    /// Turns the debug log on or off. On: a header describing the machine and
    /// the current state, then a heartbeat once a minute; per-gesture lines
    /// come from the callback. Safe to call before `start()`.
    public func setDebugLogging(_ enabled: Bool) {
        assert(Thread.isMainThread)
        Log.setDebugEnabled(enabled)
        heartbeat?.invalidate()
        heartbeat = nil
        guard enabled else { return }

        logEnvironment()
        heartbeatFrames = stateLock.withLock { $0.frames }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.logHeartbeat()
        }
        heartbeat?.tolerance = 5
    }

    private func logEnvironment() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var model = [CChar](repeating: 0, count: 64)
        var size = model.count
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let (enabled, threshold, multiplier, pid) = stateLock.withLock {
            ($0.detector.isEnabled, $0.detector.threshold, $0.detector.directionMultiplier, $0.chromePid)
        }

        Log.debug("TabSwipe \(version) on macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), "
            + "\(String(cString: model)); MTTouch is \(MemoryLayout<MTTouch>.size) bytes; "
            + "MultitouchSupport \(mt == nil ? "unavailable" : "loaded")")
        Log.debug("Accessibility granted: \(AXIsProcessTrusted()); engine \(isRunning ? "running" : "stopped"); "
            + "enabled \(enabled), threshold \(threshold), direction \(multiplier < 0 ? "RTL" : "LTR"); "
            + (pid.map { "Chrome frontmost (pid \($0))" } ?? "Chrome not frontmost"))
        for (i, device) in devices.enumerated() {
            Log.debug("Device \(i): \(mt?.describe(device) ?? "?")")
        }
    }

    private func logHeartbeat() {
        let (frames, last, pid) = stateLock.withLock { ($0.frames, $0.lastFrameTime, $0.chromePid) }
        let delta = frames - heartbeatFrames
        heartbeatFrames = frames
        let lastSeen = last == 0 ? "no frame since launch" : "last frame \(Int(CFAbsoluteTimeGetCurrent() - last))s ago"
        let running = devices.map { device -> String in
            guard let isRunning = mt?.deviceIsRunning else { return "?" }
            return isRunning(device) ? "running" : "NOT running"
        }
        Log.debug("Heartbeat: \(delta) touch frames in the last minute, \(lastSeen); "
            + "devices \(running); \(pid.map { "Chrome frontmost (pid \($0))" } ?? "Chrome not frontmost"); "
            + "Accessibility \(AXIsProcessTrusted() ? "granted" : "NOT granted")")
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
