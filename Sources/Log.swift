import os

/// Thin wrapper over the unified logging system. View with Console.app or:
///   log show --predicate 'subsystem == "com.tabswipe.app"' --last 1h
public enum Log {
    private static let logger = Logger(subsystem: "com.tabswipe.app", category: "app")

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    /// Default level, which unified logging persists to disk — unlike `info`,
    /// which is memory-only and gone within hours. Use for the lifecycle events
    /// worth reading after the fact: start, stop, sleep/wake, re-attach.
    public static func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    public static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }
}
