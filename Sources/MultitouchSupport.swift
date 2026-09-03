import Foundation

// MARK: - MultitouchSupport Private API
//
// MultitouchSupport is the only way to observe raw trackpad touches
// system-wide: NSEvent global monitors don't deliver other apps' gesture
// events, and CGEventTaps never see three-finger swipes the WindowServer
// has already claimed for Spaces/Mission Control. Every gesture utility in
// this class (BetterTouchTool, Multitouch, ...) uses this same framework.
//
// Because it is private, we bind it at runtime via dlopen/dlsym rather than
// hard-linking. If a future macOS removes or renames a symbol, the app still
// launches — gestures disable and the menu shows a warning — instead of
// being killed by dyld before main() with no user-visible explanation.

typealias MTDeviceRef = UnsafeMutableRawPointer

struct MTPoint { var x: Float; var y: Float }
struct MTReadout { var pos: MTPoint; var vel: MTPoint }

/// Reverse-engineered layout of one touch contact, stable since ~10.5
/// (96 bytes on arm64). Swift doesn't formally guarantee C-compatible
/// struct layout, so the touch callback sanity-checks `normalized.pos`
/// before trusting a frame — if Apple ever shifts a field, we drop data
/// rather than act on garbage.
struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32          // 4 = touching
    var fingerID: Int32
    var handID: Int32
    var normalized: MTReadout
    var size: Float
    var zero1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var mm: MTReadout
    var zero2a: Int32
    var zero2b: Int32
    var density: Float
}

typealias MTContactCallback = @convention(c) (
    MTDeviceRef,
    UnsafeMutableRawPointer,
    Int32,
    Double,
    Int32
) -> Void

/// The subset of MultitouchSupport we use, resolved once at first access.
/// `shared` is nil when the framework or a required symbol is missing —
/// callers treat that as "gestures unavailable", never as a crash.
struct MTFramework {
    typealias CreateListFn = @convention(c) () -> UnsafeMutableRawPointer?
    typealias RegisterFn = @convention(c) (MTDeviceRef, MTContactCallback) -> Void
    typealias StartFn = @convention(c) (MTDeviceRef, Int32) -> Int32
    typealias StopFn = @convention(c) (MTDeviceRef) -> Void
    typealias PredicateFn = @convention(c) (MTDeviceRef) -> Bool
    typealias DeviceIDFn = @convention(c) (MTDeviceRef, UnsafeMutablePointer<UInt64>) -> Int32
    typealias FamilyIDFn = @convention(c) (MTDeviceRef, UnsafeMutablePointer<Int32>) -> Int32

    private let createListFn: CreateListFn
    let registerContactFrameCallback: RegisterFn
    let deviceStart: StartFn
    let deviceStop: StopFn
    let unregisterContactFrameCallback: RegisterFn?

    // Informational only, for the debug log and the post-start sanity check.
    // Each is optional: nothing depends on them, so a macOS that lacks one
    // just logs less.
    let deviceIsBuiltIn: PredicateFn?
    let deviceIsRunning: PredicateFn?
    let deviceGetID: DeviceIDFn?
    let deviceGetFamilyID: FamilyIDFn?

    /// MTDeviceCreateList follows the CF Create rule (+1); the returned array
    /// must be kept alive as long as its MTDeviceRef elements are in use.
    func createDeviceList() -> CFArray? {
        guard let ptr = createListFn() else { return nil }
        return Unmanaged<CFArray>.fromOpaque(ptr).takeRetainedValue()
    }

    static let shared: MTFramework? = {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW) else {
            Log.error("dlopen failed for MultitouchSupport: \(String(cString: dlerror()))")
            return nil
        }
        func sym<T>(_ name: String, as type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let create = sym("MTDeviceCreateList", as: CreateListFn.self),
              let register = sym("MTRegisterContactFrameCallback", as: RegisterFn.self),
              let start = sym("MTDeviceStart", as: StartFn.self),
              let stop = sym("MTDeviceStop", as: StopFn.self)
        else {
            Log.error("MultitouchSupport symbols not found — gesture detection unavailable")
            return nil
        }
        return MTFramework(
            createListFn: create,
            registerContactFrameCallback: register,
            deviceStart: start,
            deviceStop: stop,
            // Optional: absent on some macOS versions; stop() copes without it.
            unregisterContactFrameCallback: sym("MTUnregisterContactFrameCallback", as: RegisterFn.self),
            deviceIsBuiltIn: sym("MTDeviceIsBuiltIn", as: PredicateFn.self),
            deviceIsRunning: sym("MTDeviceIsRunning", as: PredicateFn.self),
            deviceGetID: sym("MTDeviceGetDeviceID", as: DeviceIDFn.self),
            deviceGetFamilyID: sym("MTDeviceGetFamilyID", as: FamilyIDFn.self)
        )
    }()

    /// One line for the log: which trackpad this is and whether the framework
    /// thinks it is delivering. Family 110 is the built-in trackpad on Apple
    /// silicon MacBooks; other families are external Magic devices.
    func describe(_ device: MTDeviceRef) -> String {
        var parts = [String(format: "%p", Int(bitPattern: device))]
        var id: UInt64 = 0
        if let getID = deviceGetID, getID(device, &id) == 0 {
            parts.append("id 0x" + String(id, radix: 16))
        }
        var family: Int32 = 0
        if let getFamily = deviceGetFamilyID, getFamily(device, &family) == 0 {
            parts.append("family \(family)")
        }
        if let isBuiltIn = deviceIsBuiltIn {
            parts.append(isBuiltIn(device) ? "built-in" : "external")
        }
        if let isRunning = deviceIsRunning {
            parts.append(isRunning(device) ? "running" : "NOT running")
        }
        return parts.joined(separator: ", ")
    }
}
