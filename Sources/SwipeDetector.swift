import Foundation

public enum SwipeEvent: Equatable {
    case next
    case previous
}

let kSwipeThresholdMin: Float = 0.012
let kSwipeThresholdMax: Float = 0.12

/// Converts a swipe-distance level (1-10) to a threshold in normalized trackpad
/// width. Level 1 = shortest travel per tab, level 10 = longest.
public func thresholdForLevel(_ level: Int) -> Float {
    let clamped = Float(min(max(level, 1), 10))
    return kSwipeThresholdMin + (kSwipeThresholdMax - kSwipeThresholdMin) * (clamped - 1) / 9.0
}

/// Pure gesture state machine: feed it per-frame touch summaries, it decides
/// when a tab switch fires. No I/O, no locking — fully unit-testable.
public struct SwipeDetector {
    public var isEnabled = true
    public var threshold: Float = kSwipeThresholdMax
    public var directionMultiplier: Float = -1.0  // RTL default: swipe right = next tab

    /// Minimum pause between fires; paces continuous swipes without losing distance.
    public static let cooldown: Double = 0.15
    /// Vertical travel from gesture start that aborts the gesture — the user is
    /// doing a system gesture (Mission Control etc.), not a tab swipe.
    public static let verticalAbortDistance: Float = 0.08

    private var tracking = false
    private var suppressed = false   // set on 4+ fingers or vertical abort; cleared only when all fingers lift
    private var startX: Float = 0
    private var startY: Float = 0
    private var lastSwitchX: Float = 0
    private var lastFireTime: Double = -.infinity

    public init() {}

    public mutating func process(touchCount: Int, avgX: Float, avgY: Float, timestamp: Double) -> SwipeEvent? {
        guard isEnabled else {
            reset()
            return nil
        }

        if touchCount == 0 {
            tracking = false
            suppressed = false
            return nil
        }
        if touchCount > 3 {
            tracking = false
            suppressed = true
            return nil
        }
        guard touchCount == 3, !suppressed else {
            tracking = false
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

        if abs(totalDy) > Self.verticalAbortDistance && abs(totalDy) > abs(totalDx) {
            tracking = false
            suppressed = true
            return nil
        }

        let deltaX = avgX - lastSwitchX
        guard abs(deltaX) >= threshold, abs(totalDx) > 2 * abs(totalDy) else { return nil }

        if timestamp - lastFireTime > Self.cooldown {
            lastFireTime = timestamp
            lastSwitchX = avgX
            return (deltaX * directionMultiplier) < 0 ? .next : .previous
        }

        // In cooldown: keep exactly one threshold-worth pending so a fast swipe
        // paces at the cooldown rate instead of silently discarding distance.
        lastSwitchX = avgX - (deltaX > 0 ? threshold : -threshold)
        return nil
    }

    public mutating func reset() {
        tracking = false
        suppressed = false
    }
}
