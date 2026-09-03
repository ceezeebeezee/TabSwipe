import Foundation
import os

/// Thin wrapper over the unified logging system, plus an opt-in debug mode.
///
/// Levels, and where each one ends up:
///  - `notice` / `error`: the unified log at default/error level, which macOS
///    persists to disk. Lifecycle events only — start, stop, sleep/wake,
///    re-attach — so the story is readable after the fact without noise.
///  - `info`: memory-only, gone within hours. Chatter.
///  - `debug`: nothing at all unless Debug Logging is on. Then it goes both to
///    the unified log (category "debug", persisted) and to a plain-text file
///    the user can attach to a bug report. Per-gesture detail lives here.
///
/// While Debug Logging is on, `notice` and `error` are mirrored into the file
/// too, so the file alone tells the whole story.
///
/// Unified log: Console.app, or
///   log show --predicate 'subsystem == "com.tabswipe.app"' --last 1h
public enum Log {
    private static let logger = Logger(subsystem: "com.tabswipe.app", category: "app")
    private static let debugLogger = Logger(subsystem: "com.tabswipe.app", category: "debug")

    /// Read on the touch-callback thread for every frame, hence a lock rather
    /// than a bare static.
    private static let debugFlag = OSAllocatedUnfairLock(initialState: false)
    public static var isDebugEnabled: Bool { debugFlag.withLock { $0 } }

    /// ~/Library/Logs/TabSwipe/ — Console.app lists it under Log Reports, and
    /// Uninstall removes it (see `supportFileURLs` in App.swift).
    public static let logDirectoryURL: URL = {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return library.appendingPathComponent("Logs/TabSwipe", isDirectory: true)
    }()
    public static let logFileURL = logDirectoryURL.appendingPathComponent("TabSwipe.log")

    /// Disk writes happen here, never on the caller's thread: the touch
    /// callback must not block on I/O.
    private static let fileQueue = DispatchQueue(label: "com.tabswipe.app.log", qos: .utility)
    /// Past this the file rolls over to TabSwipe.log.1, which is replaced.
    private static let maxFileSize: UInt64 = 4 * 1024 * 1024
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public static func setDebugEnabled(_ enabled: Bool) {
        let changed = debugFlag.withLock { flag -> Bool in
            let changed = flag != enabled
            if enabled { flag = true }   // turning off waits until the last line is mirrored
            return changed
        }
        guard changed else { return }
        if enabled {
            notice("Debug logging on — writing to \(logFileURL.path)")
        } else {
            notice("Debug logging off")
            debugFlag.withLock { $0 = false }
        }
    }

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        mirror("info", message)
    }

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        mirror("error", message)
    }

    public static func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        mirror("notice", message)
    }

    /// An autoclosure so that callers on the hot path pay nothing for the
    /// string when debug logging is off — not even the interpolation.
    public static func debug(_ message: @autoclosure () -> String) {
        guard isDebugEnabled else { return }
        let text = message()
        debugLogger.notice("\(text, privacy: .public)")
        append("debug", text)
    }

    private static func mirror(_ level: String, _ message: String) {
        guard isDebugEnabled else { return }
        append(level, message)
    }

    private static func append(_ level: String, _ message: String) {
        let stamp = Date()
        fileQueue.async {
            write("\(timestampFormatter.string(from: stamp)) [\(level)] \(message)\n")
        }
    }

    private static func write(_ line: String) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
            if let size = try? fm.attributesOfItem(atPath: logFileURL.path)[.size] as? UInt64,
               size > maxFileSize {
                let rolled = logDirectoryURL.appendingPathComponent("TabSwipe.log.1")
                try? fm.removeItem(at: rolled)
                try fm.moveItem(at: logFileURL, to: rolled)
            }
            if !fm.fileExists(atPath: logFileURL.path) {
                fm.createFile(atPath: logFileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logFileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            logger.error("Debug log write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
