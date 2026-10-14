// Standalone dylib used only by run.py. No real trackpad or private framework is touched.
import Foundation
import CoreFoundation

private typealias ContactCallback = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
) -> Int32
private var callbacks: [UnsafeMutableRawPointer: ContactCallback] = [:]
private var emptyDiscovery = false
private var unregisterDelay: Double = 0
private var stoppedCount: Int32 = 0

@_cdecl("MTDeviceCreateList")
public func fakeCreateList() -> UnsafeMutableRawPointer? {
    let array = (emptyDiscovery ? [] : [NSObject(), NSObject()]) as NSArray
    return Unmanaged.passRetained(unsafeBitCast(array, to: CFArray.self)).toOpaque()
}

@_cdecl("MTRegisterContactFrameCallback")
public func fakeRegister(_ device: UnsafeMutableRawPointer?, _ callback: UnsafeMutableRawPointer?) {
    if let device, let callback {
        callbacks[device] = unsafeBitCast(callback, to: ContactCallback.self)
    }
}

@_cdecl("MTUnregisterContactFrameCallback")
public func fakeUnregister(_ device: UnsafeMutableRawPointer?, _ callback: UnsafeMutableRawPointer?) {
    if let device { callbacks.removeValue(forKey: device) }
    if unregisterDelay > 0 { Thread.sleep(forTimeInterval: unregisterDelay) }
}

@_cdecl("MTDeviceStart")
public func fakeStart(_ device: UnsafeMutableRawPointer?, _ mode: Int32) {}

@_cdecl("MTDeviceStop")
public func fakeStop(_ device: UnsafeMutableRawPointer?) { stoppedCount += 1 }

@_cdecl("SwitchRegressionSetEmptyDiscovery")
public func setEmptyDiscovery(_ empty: Int32) { emptyDiscovery = empty != 0 }

@_cdecl("SwitchRegressionSetUnregisterDelay")
public func setUnregisterDelay(_ delay: Double) { unregisterDelay = delay }

@_cdecl("SwitchRegressionStopCount")
public func stopCount() -> Int32 { stoppedCount }

@_cdecl("SwitchRegressionEmitFrame")
public func emitFrame(_ device: UnsafeMutableRawPointer?, _ touches: UnsafeMutableRawPointer?, _ count: Int32) {
    if let device, let callback = callbacks[device] {
        _ = callback(device, touches, count, 0, 0)
    }
}
