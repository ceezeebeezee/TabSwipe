import Foundation

public enum SwipeEvent: Equatable {
    case next
    case previous
}

/// Swipe-distance bounds, in normalized trackpad width (0...1).
/// 0.12 ≈ 1.6 cm of travel per tab switch on a MacBook trackpad.
let kSwipeThresholdMin: Float = 0.012
let kSwipeThresholdMax: Float = 0.12

/// Maps the user-facing swipe-distance level (1–10) onto a threshold.
/// Level 1 = shortest travel per tab, level 10 = longest. Out-of-range
/// levels clamp rather than trap, since the value round-trips through
/// UserDefaults and could be anything.
public func thresholdForLevel(_ level: Int) -> Float {
    let clamped = Float(min(max(level, 1), 10))
    return kSwipeThresholdMin + (kSwipeThresholdMax - kSwipeThresholdMin) * (clamped - 1) / 9.0
}

/// The gesture brain: feed it one touch-frame summary at a time and it
/// decides when a tab switch fires. Pure value type — no I/O, no clock,
/// no locking — so every rule below is unit-tested in isolation.
///
/// Rules of the gesture:
///  1. Exactly three fingers arm tracking; the arm position is the baseline.
///  2. A tab switch fires per `threshold` of horizontal travel, so one long
///     swipe glides through several tabs.
///  3. Vertical intent cancels: once travel is mostly vertical the user is
///     doing a system gesture (Mission Control), not switching tabs, and the
///     gesture stays dead until every finger lifts.
///  4. Four or more fingers likewise suppress until every finger lifts, so
///     the tail end of a system gesture can't masquerade as a swipe.
///  5. The cooldown paces repeat fires without discarding distance —
///     a fast swipe crosses the same number of tabs as a slow one.
public struct SwipeDetector {
    public var isEnabled = true
    public var threshold: Float = kSwipeThresholdMax
    public var directionMultiplier: Float = -1.0  // RTL default: swipe right = next tab

    /// Minimum pause between fires (rule 5).
    public static let cooldown: Double = 0.15
    /// Vertical travel from the arm position that cancels the gesture (rule 3).
    public static let verticalAbortDistance: Float = 0.08

    private var tracking = false
    private var suppressed = false   // rules 3 & 4: dead until all fingers lift

    /// Read-only views of the gesture state, for the debug log.
    public var isTracking: Bool { tracking }
    public var isSuppressed: Bool { suppressed }
    private var startX: Float = 0
    private var startY: Float = 0
    private var lastSwitchX: Float = 0
    private var lastFireTime: Double = -.infinity

    public init() {}

    /// Processes one touch frame. `avgX`/`avgY` are the mean finger position
    /// in normalized trackpad coordinates; `timestamp` is in seconds (any
    /// monotonic clock — only differences matter).
    public mutating func process(touchCount: Int, avgX: Float, avgY: Float, timestamp: Double) -> SwipeEvent? {
        guard isEnabled else {
            reset()
            return nil
        }

        if touchCount == 0 {
            tracking = false
            suppressed = false        // all fingers lifted: forgive everything
            return nil
        }
        if touchCount > 3 {
            tracking = false
            suppressed = true         // rule 4
            return nil
        }
        guard touchCount == 3, !suppressed else {
            tracking = false          // 1–2 fingers: idle, but not suppressed
            return nil
        }

        if !tracking {
            tracking = true
            startX = avgX
            startY = avgY
            lastSwitchX = avgX
            return nil
        }

        let totalDx = avgX - startX
        let totalDy = avgY - startY

        // Rule 3: clearly vertical → this is not our gesture.
        if abs(totalDy) > Self.verticalAbortDistance && abs(totalDy) > abs(totalDx) {
            tracking = false
            suppressed = true
            return nil
        }

        // Rule 2: fire only on a threshold-worth of travel that is
        // decisively horizontal (2:1 over vertical drift).
        let deltaX = avgX - lastSwitchX
        guard abs(deltaX) >= threshold, abs(totalDx) > 2 * abs(totalDy) else { return nil }

        // The clock is the trackpad's own. Stopping and restarting the device
        // — which happens after every wake — may restart it, and a last-fire
        // time from before would then sit in the future and hold the cooldown
        // shut for as long as the app runs. A backwards jump counts as expired.
        let sinceLastFire = timestamp - lastFireTime
        if sinceLastFire > Self.cooldown || sinceLastFire < 0 {
            lastFireTime = timestamp
            lastSwitchX = avgX
            return (deltaX * directionMultiplier) < 0 ? .next : .previous
        }

        // Rule 5: in cooldown, bank exactly one threshold-worth of travel.
        // The swipe then paces at the cooldown rate instead of silently
        // losing distance — which would make tab count depend on speed.
        lastSwitchX = avgX - (deltaX > 0 ? threshold : -threshold)
        return nil
    }

    public mutating func reset() {
        tracking = false
        suppressed = false
        lastFireTime = -.infinity
    }
}
