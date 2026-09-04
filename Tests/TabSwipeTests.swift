// Standalone test runner — no XCTest/Xcode required
import Foundation
import TabSwipeCore

// MARK: - Mini Test Framework

var totalTests = 0
var passedTests = 0
var failedTests: [(String, String)] = []

func test(_ name: String, _ body: () throws -> Void) {
    totalTests += 1
    do {
        try body()
        passedTests += 1
        print("  ✓ \(name)")
    } catch {
        failedTests.append((name, "\(error)"))
        print("  ✗ \(name): \(error)")
    }
}

struct AssertionError: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: Bool, _ message: String = "Assertion failed") throws {
    guard condition else { throw AssertionError(description: message) }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "") throws {
    guard a == b else {
        throw AssertionError(description: "\(message) — expected \(b), got \(a)")
    }
}

func expectClose(_ a: Float, _ b: Float, accuracy: Float = 0.001, _ message: String = "") throws {
    guard abs(a - b) < accuracy else {
        throw AssertionError(description: "\(message) — expected ~\(b), got \(a)")
    }
}

// MARK: - Threshold Tests

func runThresholdTests() {
    print("\n── Threshold Calculation ──")

    test("Level 1 is minimum") {
        try expectClose(thresholdForLevel(1), 0.012)
    }

    test("Level 10 is maximum") {
        try expectClose(thresholdForLevel(10), 0.12)
    }

    test("Level 5 is midpoint") {
        let expected: Float = 0.012 + (0.12 - 0.012) * 4.0 / 9.0
        try expectClose(thresholdForLevel(5), expected)
    }

    test("Monotonically increasing") {
        var prev: Float = 0
        for level in 1...10 {
            let threshold = thresholdForLevel(level)
            try expect(threshold > prev, "Level \(level) (\(threshold)) not > level \(level-1) (\(prev))")
            prev = threshold
        }
    }

    test("Clamps below minimum (0 → 1)") {
        try expectClose(thresholdForLevel(0), thresholdForLevel(1))
    }

    test("Clamps above maximum (99 → 10)") {
        try expectClose(thresholdForLevel(99), thresholdForLevel(10))
    }

    test("Clamps negative (-5 → 1)") {
        try expectClose(thresholdForLevel(-5), thresholdForLevel(1))
    }
}

// MARK: - Swipe Detector Tests

func runDetectorTests() {
    print("\n── Swipe Detector ──")

    func makeDetector(level: Int = 5, direction: Float = -1.0) -> SwipeDetector {
        var d = SwipeDetector()
        d.threshold = thresholdForLevel(level)
        d.directionMultiplier = direction
        return d
    }

    test("Arms on 3 fingers without firing") {
        var d = makeDetector()
        try expectEqual(d.process(touchCount: 3, avgX: 0.5, avgY: 0.5, timestamp: 1.0), nil)
    }

    test("Right swipe fires .next with RTL direction") {
        var d = makeDetector(direction: -1.0)
        _ = d.process(touchCount: 3, avgX: 0.3, avgY: 0.5, timestamp: 1.0)
        let e = d.process(touchCount: 3, avgX: 0.3 + d.threshold * 1.5, avgY: 0.5, timestamp: 1.05)
        try expectEqual(e, SwipeEvent.next)
    }

    test("Left swipe fires .previous with RTL direction") {
        var d = makeDetector(direction: -1.0)
        _ = d.process(touchCount: 3, avgX: 0.7, avgY: 0.5, timestamp: 1.0)
        let e = d.process(touchCount: 3, avgX: 0.7 - d.threshold * 1.5, avgY: 0.5, timestamp: 1.05)
        try expectEqual(e, SwipeEvent.previous)
    }

    test("Right swipe fires .previous with LTR direction") {
        var d = makeDetector(direction: 1.0)
        _ = d.process(touchCount: 3, avgX: 0.3, avgY: 0.5, timestamp: 1.0)
        let e = d.process(touchCount: 3, avgX: 0.3 + d.threshold * 1.5, avgY: 0.5, timestamp: 1.05)
        try expectEqual(e, SwipeEvent.previous)
    }

    test("Sub-threshold movement does not fire") {
        var d = makeDetector()
        _ = d.process(touchCount: 3, avgX: 0.5, avgY: 0.5, timestamp: 1.0)
        try expectEqual(d.process(touchCount: 3, avgX: 0.5 + d.threshold * 0.9, avgY: 0.5, timestamp: 1.05), nil)
    }

    test("Disabled detector never fires") {
        var d = makeDetector()
        d.isEnabled = false
        _ = d.process(touchCount: 3, avgX: 0.3, avgY: 0.5, timestamp: 1.0)
        try expectEqual(d.process(touchCount: 3, avgX: 0.9, avgY: 0.5, timestamp: 2.0), nil)
    }

    test("Cooldown blocks immediate repeat fire") {
        var d = makeDetector()
        _ = d.process(touchCount: 3, avgX: 0.2, avgY: 0.5, timestamp: 1.0)
        try expect(d.process(touchCount: 3, avgX: 0.2 + d.threshold * 1.5, avgY: 0.5, timestamp: 1.05) != nil, "First fire")
        // Within cooldown — must not fire again
        try expectEqual(d.process(touchCount: 3, avgX: 0.2 + d.threshold * 4, avgY: 0.5, timestamp: 1.1), nil)
    }

    test("Cooldown paces without discarding distance") {
        var d = makeDetector()
        _ = d.process(touchCount: 3, avgX: 0.2, avgY: 0.5, timestamp: 1.0)
        try expect(d.process(touchCount: 3, avgX: 0.2 + d.threshold * 1.5, avgY: 0.5, timestamp: 1.05) != nil, "First fire")
        // Blocked by cooldown, but one threshold-worth stays pending...
        _ = d.process(touchCount: 3, avgX: 0.2 + d.threshold * 4, avgY: 0.5, timestamp: 1.1)
        // ...so after cooldown expires, the same position fires again with no new movement
        let e = d.process(touchCount: 3, avgX: 0.2 + d.threshold * 4.01, avgY: 0.5, timestamp: 1.3)
        try expectEqual(e, SwipeEvent.next, "Pending distance should fire after cooldown")
    }

    test("Continuous swipe fires repeatedly when spaced past cooldown") {
        var d = makeDetector()
        _ = d.process(touchCount: 3, avgX: 0.1, avgY: 0.5, timestamp: 1.0)
        var fires = 0
        for i in 1...4 {
            let x = 0.1 + Float(i) * d.threshold * 1.2
            if d.process(touchCount: 3, avgX: x, avgY: 0.5, timestamp: 1.0 + Double(i) * 0.2) != nil {
                fires += 1
            }
        }
        try expectEqual(fires, 4, "Each spaced threshold crossing should fire")
    }

    test("Vertical movement aborts gesture until fingers lift") {
        var d = makeDetector()
        _ = d.process(touchCount: 3, avgX: 0.5, avgY: 0.3, timestamp: 1.0)
        // Mostly-vertical move past the abort distance
        try expectEqual(d.process(touchCount: 3, avgX: 0.52, avgY: 0.3 + 0.15, timestamp: 1.05), nil)
        // Now a big horizontal move must NOT fire — gesture is dead
        try expectEqual(d.process(touchCount: 3, avgX: 0.9, avgY: 0.45, timestamp: 1.5), nil)
        // Lift all fingers, re-arm, and it works again
        _ = d.process(touchCount: 0, avgX: 0, avgY: 0, timestamp: 2.0)
        _ = d.process(touchCount: 3, avgX: 0.3, avgY: 0.5, timestamp: 2.1)
        try expectEqual(d.process(touchCount: 3, avgX: 0.3 + d.threshold * 1.5, avgY: 0.5, timestamp: 2.4), SwipeEvent.next)
    }

    test("Diagonal movement without horizontal dominance does not fire") {
        var d = makeDetector()
        _ = d.process(touchCount: 3, avgX: 0.5, avgY: 0.5, timestamp: 1.0)
        // dx over threshold but dy is comparable (not 2x dominated)
        let dx = d.threshold * 1.5
        try expectEqual(d.process(touchCount: 3, avgX: 0.5 + dx, avgY: 0.5 + dx * 0.7, timestamp: 1.3), nil)
    }

    test("4+ fingers suppresses until all fingers lift") {
        var d = makeDetector()
        _ = d.process(touchCount: 4, avgX: 0.5, avgY: 0.5, timestamp: 1.0)
        // Lifting one finger of a 4-finger gesture must not arm 3-finger tracking
        _ = d.process(touchCount: 3, avgX: 0.5, avgY: 0.5, timestamp: 1.05)
        try expectEqual(d.process(touchCount: 3, avgX: 0.9, avgY: 0.5, timestamp: 1.3), nil)
        // After full lift, 3-finger swipe works again
        _ = d.process(touchCount: 0, avgX: 0, avgY: 0, timestamp: 2.0)
        _ = d.process(touchCount: 3, avgX: 0.3, avgY: 0.5, timestamp: 2.1)
        try expectEqual(d.process(touchCount: 3, avgX: 0.3 + d.threshold * 1.5, avgY: 0.5, timestamp: 2.4), SwipeEvent.next)
    }

    test("Dropping to 2 fingers resets tracking baseline") {
        var d = makeDetector()
        _ = d.process(touchCount: 3, avgX: 0.2, avgY: 0.5, timestamp: 1.0)
        _ = d.process(touchCount: 2, avgX: 0.5, avgY: 0.5, timestamp: 1.1)
        // Re-arm at new position; old baseline must not carry over into a fire
        try expectEqual(d.process(touchCount: 3, avgX: 0.6, avgY: 0.5, timestamp: 1.2), nil)
        try expectEqual(d.process(touchCount: 3, avgX: 0.6 + d.threshold * 1.5, avgY: 0.5, timestamp: 1.5), SwipeEvent.next)
    }

    test("Cooldown survives the device clock restarting from zero") {
        // After a sleep/wake re-attach the trackpad's timestamps may restart.
        var d = makeDetector()
        _ = d.process(touchCount: 3, avgX: 0.3, avgY: 0.5, timestamp: 5000.0)
        try expectEqual(d.process(touchCount: 3, avgX: 0.3 + d.threshold * 1.5, avgY: 0.5, timestamp: 5000.05), SwipeEvent.next)
        _ = d.process(touchCount: 0, avgX: 0, avgY: 0, timestamp: 5000.2)
        // Clock jumps backwards: a fresh gesture must still fire.
        _ = d.process(touchCount: 3, avgX: 0.3, avgY: 0.5, timestamp: 0.1)
        try expectEqual(d.process(touchCount: 3, avgX: 0.3 + d.threshold * 1.5, avgY: 0.5, timestamp: 0.15), SwipeEvent.next)
    }

    test("Reset clears suppression, tracking and the cooldown") {
        var d = makeDetector()
        _ = d.process(touchCount: 4, avgX: 0.5, avgY: 0.5, timestamp: 1.0)
        try expect(d.isSuppressed, "Four fingers should suppress")
        d.reset()
        try expect(!d.isSuppressed && !d.isTracking, "Reset should clear gesture state")
        _ = d.process(touchCount: 3, avgX: 0.3, avgY: 0.5, timestamp: 1.1)
        try expect(d.isTracking, "Should arm after reset without waiting for a lift")
        try expectEqual(d.process(touchCount: 3, avgX: 0.3 + d.threshold * 1.5, avgY: 0.5, timestamp: 1.15), SwipeEvent.next)
    }

    test("isTracking and isSuppressed reflect the gesture state") {
        var d = makeDetector()
        try expect(!d.isTracking, "Idle at start")
        _ = d.process(touchCount: 3, avgX: 0.5, avgY: 0.5, timestamp: 1.0)
        try expect(d.isTracking, "Three fingers arm tracking")
        _ = d.process(touchCount: 3, avgX: 0.5, avgY: 0.5 + SwipeDetector.verticalAbortDistance * 1.5, timestamp: 1.05)
        try expect(d.isSuppressed && !d.isTracking, "Vertical movement suppresses")
        _ = d.process(touchCount: 0, avgX: 0, avgY: 0, timestamp: 1.1)
        try expect(!d.isSuppressed, "Lifting every finger forgives")
    }
}

// MARK: - Chrome Target Tests

func runChromeTargetTests() {
    print("\n── Chrome Target ──")

    test("Chrome itself is a target") {
        try expect(isChromeBundleIdentifier("com.google.Chrome"), "browser")
    }

    test("Installed web app shims are targets") {
        try expect(isChromeBundleIdentifier("com.google.Chrome.app.fmgjjmmmlfnkbppncabfkddbjimcfncm"), "Gmail window")
    }

    test("Release channels are targets") {
        for id in ["com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary"] {
            try expect(isChromeBundleIdentifier(id), id)
        }
    }

    test("Helper and framework processes are not targets") {
        try expect(!isChromeBundleIdentifier("com.google.Chrome.helper"), "helper")
        try expect(!isChromeBundleIdentifier("com.google.Chrome.helper.renderer"), "renderer")
        try expect(!isChromeBundleIdentifier("com.google.Chrome.framework.AlertNotificationService"), "framework")
    }

    test("Other apps and nil are not targets") {
        try expect(!isChromeBundleIdentifier("com.apple.Safari"), "Safari")
        try expect(!isChromeBundleIdentifier("com.apple.loginwindow"), "lock screen")
        try expect(!isChromeBundleIdentifier(nil), "nil")
    }
}

// MARK: - Engine Apply Tests

func runEngineTests() {
    print("\n── Engine Apply ──")
    let engine = GestureEngine.shared

    test("Apply enabled = true") {
        engine.apply(enabled: true, swipeLevel: 5, direction: "RTL")
        try expect(engine.currentEnabled, "Should be enabled")
    }

    test("Apply enabled = false") {
        engine.apply(enabled: false, swipeLevel: 5, direction: "RTL")
        try expect(!engine.currentEnabled, "Should be disabled")
    }

    test("Direction RTL → multiplier -1.0") {
        engine.apply(enabled: true, swipeLevel: 5, direction: "RTL")
        try expectClose(engine.currentDirectionMultiplier, -1.0)
    }

    test("Direction LTR → multiplier 1.0") {
        engine.apply(enabled: true, swipeLevel: 5, direction: "LTR")
        try expectClose(engine.currentDirectionMultiplier, 1.0)
    }

    test("Unknown direction defaults to RTL") {
        engine.apply(enabled: true, swipeLevel: 5, direction: "GARBAGE")
        try expectClose(engine.currentDirectionMultiplier, -1.0)
    }

    test("Swipe level sets correct threshold for all levels") {
        for level in 1...10 {
            engine.apply(enabled: true, swipeLevel: level, direction: "RTL")
            try expectClose(engine.currentThreshold, thresholdForLevel(level),
                          "Level \(level)")
        }
    }

    test("Swipe level clamps out-of-range values") {
        engine.apply(enabled: true, swipeLevel: 0, direction: "RTL")
        try expectClose(engine.currentThreshold, thresholdForLevel(1))
        engine.apply(enabled: true, swipeLevel: 100, direction: "RTL")
        try expectClose(engine.currentThreshold, thresholdForLevel(10))
    }
}

// MARK: - Settings Persistence Tests

func runSettingsTests() {
    print("\n── Settings Persistence ──")

    let keys = ["swipeLevel", "direction", "isEnabled", "hasShownSetupTips", "debugLogging"]
    keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }

    test("Default swipeLevel is 10") {
        let s = AppSettings()
        try expectEqual(s.swipeLevel, 10)
    }

    test("Default direction is RTL") {
        let s = AppSettings()
        try expectEqual(s.direction, "RTL")
    }

    test("Default isEnabled is true") {
        let s = AppSettings()
        try expect(s.isEnabled, "Should default to enabled")
    }

    test("Default hasShownSetupTips is false") {
        let s = AppSettings()
        try expect(!s.hasShownSetupTips, "Should default to not shown")
    }

    test("Default debugLogging is false") {
        let s = AppSettings()
        try expect(!s.debugLogging, "Debug logging must be opt-in")
    }

    test("Persists debugLogging") {
        let s = AppSettings()
        s.debugLogging = true
        try expect(UserDefaults.standard.bool(forKey: "debugLogging"), "Should persist true")
        s.debugLogging = false
    }

    test("Persists swipeLevel") {
        let s = AppSettings()
        s.swipeLevel = 3
        try expectEqual(UserDefaults.standard.integer(forKey: "swipeLevel"), 3)
    }

    test("Persists direction") {
        let s = AppSettings()
        s.direction = "LTR"
        try expectEqual(UserDefaults.standard.string(forKey: "direction"), "LTR")
    }

    test("Persists isEnabled") {
        let s = AppSettings()
        s.isEnabled = false
        try expect(!UserDefaults.standard.bool(forKey: "isEnabled"), "Should persist false")
    }

    test("Persists hasShownSetupTips") {
        let s = AppSettings()
        s.hasShownSetupTips = true
        try expect(UserDefaults.standard.bool(forKey: "hasShownSetupTips"), "Should persist true")
    }

    keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
}

// MARK: - Round-Trip Tests

func runRoundTripTests() {
    print("\n── Round-Trip: Settings → Engine ──")
    let engine = GestureEngine.shared

    test("Settings flow through to engine correctly") {
        let s = AppSettings()
        s.swipeLevel = 7
        s.direction = "LTR"
        s.isEnabled = false
        engine.applySettings(s)

        try expect(!engine.currentEnabled, "Should be disabled")
        try expectClose(engine.currentDirectionMultiplier, 1.0, "Should be LTR")
        try expectClose(engine.currentThreshold, thresholdForLevel(7), "Should be level 7")

        s.swipeLevel = 2
        s.direction = "RTL"
        s.isEnabled = true
        engine.applySettings(s)

        try expect(engine.currentEnabled, "Should be enabled")
        try expectClose(engine.currentDirectionMultiplier, -1.0, "Should be RTL")
        try expectClose(engine.currentThreshold, thresholdForLevel(2), "Should be level 2")

        ["swipeLevel", "direction", "isEnabled"].forEach {
            UserDefaults.standard.removeObject(forKey: $0)
        }
    }

    test("Rapid setting changes do not crash") {
        for _ in 0..<100 {
            for level in 1...10 {
                engine.apply(enabled: true, swipeLevel: level, direction: level % 2 == 0 ? "RTL" : "LTR")
            }
        }
        try expect(engine.currentEnabled, "Should still be enabled after 1000 rapid changes")
    }
}

// MARK: - Main

print("TabSwipe Test Suite")
print("===================")

runThresholdTests()
runDetectorTests()
runChromeTargetTests()
runEngineTests()
runSettingsTests()
runRoundTripTests()

print("\n===================")
print("\(passedTests)/\(totalTests) passed")

if !failedTests.isEmpty {
    print("\nFailed:")
    for (name, reason) in failedTests {
        print("  ✗ \(name): \(reason)")
    }
    exit(1)
} else {
    print("All tests passed ✓")
    exit(0)
}
