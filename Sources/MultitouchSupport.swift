import Foundation

// MARK: - MultitouchSupport Private API
//
// Loaded at runtime via dlopen/dlsym rather than hard-linking, so if a future
// macOS removes or renames these symbols the app still launches (with gestures
// disabled and a menu warning) instead of dying in dyld before main().

typealias MTDeviceRef = UnsafeMutableRawPointer

struct MTPoint { var x: Float; var y: Float }
struct MTReadout { var pos: MTPoint; var vel: MTPoint }

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

struct MTFramework {
    typealias CreateListFn = @convention(c) () -> UnsafeMutableRawPointer?
    typealias RegisterFn = @convention(c) (MTDeviceRef, MTContactCallback) -> Void
    typealias StartFn = @convention(c) (MTDeviceRef, Int32) -> Int32
    typealias StopFn = @convention(c) (MTDeviceRef) -> Void

    private let createListFn: CreateListFn
    let registerContactFrameCallback: RegisterFn
    let deviceStart: StartFn
    let deviceStop: StopFn
    let unregisterContactFrameCallback: RegisterFn?

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
            unregisterContactFrameCallback: sym("MTUnregisterContactFrameCallback", as: RegisterFn.self)
        )
    }()
}
