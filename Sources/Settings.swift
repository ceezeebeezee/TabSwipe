import Foundation

public final class AppSettings {
    public static let shared = AppSettings()

    private enum Keys {
        static let swipeLevel = "swipeLevel"
        static let direction = "direction"
        static let isEnabled = "isEnabled"
        static let hasShownSetupTips = "hasShownSetupTips"
    }

    private static let defaults = UserDefaults.standard

    /// 1-10: distance of travel per tab switch (1 = shortest, 10 = longest).
    public var swipeLevel: Int {
        get { Self.defaults.integer(forKey: Keys.swipeLevel) }
        set { Self.defaults.set(newValue, forKey: Keys.swipeLevel) }
    }

    /// "RTL" (swipe right = next tab) or "LTR" (swipe left = next tab).
    public var direction: String {
        get { Self.defaults.string(forKey: Keys.direction) ?? "RTL" }
        set { Self.defaults.set(newValue, forKey: Keys.direction) }
    }

    public var isEnabled: Bool {
        get { Self.defaults.bool(forKey: Keys.isEnabled) }
        set { Self.defaults.set(newValue, forKey: Keys.isEnabled) }
    }

    public var hasShownSetupTips: Bool {
        get { Self.defaults.bool(forKey: Keys.hasShownSetupTips) }
        set { Self.defaults.set(newValue, forKey: Keys.hasShownSetupTips) }
    }

    public init() {
        Self.defaults.register(defaults: [
            Keys.swipeLevel: 10,
            Keys.direction: "RTL",
            Keys.isEnabled: true,
            Keys.hasShownSetupTips: false
        ])
    }
}
