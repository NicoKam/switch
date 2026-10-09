import CoreGraphics
import Foundation
import Darwin

final class TrackpadGestureManager {
    var onTrackingChanged: ((Bool) -> Void)?
    var onBegin: ((HotkeyManager.Direction) -> Void)?
    var onStep: ((HotkeyManager.Direction) -> Void)?
    var onFinish: ((Bool) -> Void)?

    private struct MTPoint {
        var x: Float
        var y: Float
    }

    private struct MTVector {
        var position: MTPoint
        var velocity: MTPoint
    }

    private struct MTTouch {
        var frame: Int32
        var timestamp: Double
        var identifier: Int32
        var state: Int32
        var unknown1: Int32
        var unknown2: Int32
        var normalized: MTVector
        var size: Float
        var unknown3: Int32
        var angle: Float
        var majorAxis: Float
        var minorAxis: Float
        var millimeters: MTVector
        var unknown4: (Int32, Int32)
        var density: Float
    }

    private typealias ContactCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
    ) -> Int32
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias RegisterCallback = @convention(c) (UnsafeMutableRawPointer?, ContactCallback) -> Void
    private typealias UnregisterCallback = @convention(c) (UnsafeMutableRawPointer?, ContactCallback) -> Void
    private typealias StartDevice = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    private typealias StopDevice = @convention(c) (UnsafeMutableRawPointer?) -> Void

    private static let horizontalActivationDistance: Float = 0.0225
    private static let horizontalStepDistance: Float = 0.0275
    private static let verticalActivationDistance: Float = 0.045
    private static let verticalStepDistance: Float = 0.055

    /// A registration can go silently stale (input subsystem re-enumeration), after
    /// which no contact frames are delivered even though the trackpad is in use.
    /// When this much time passes with system touch-like input but no frames, the
    /// registration is rebuilt.
    private static let livenessThresholdNanos: UInt64 = 30 * 1_000_000_000
    private static let restartSpacingNanos: UInt64 = 60 * 1_000_000_000
    private static let callback: ContactCallback = { device, touches, count, _, _ in
        guard let device else { return 0 }
        registryLock.lock()
        let owner = owners[device]
        registryLock.unlock()
        owner?.handle(
            device: device,
            touches: touches?.assumingMemoryBound(to: MTTouch.self),
            count: Int(count)
        )
        return 0
    }
    private static let registryLock = NSLock()
    private static var owners: [UnsafeMutableRawPointer: TrackpadGestureManager] = [:]
    // Kept mapped for the process lifetime: dlclose while a contact callback is in
    // flight on a device thread would crash, and reloading costs nothing.
    private static var libraryHandle: UnsafeMutableRawPointer?

    private let stateLock = NSLock()
    private var framework: UnsafeMutableRawPointer?
    private var devices: [UnsafeMutableRawPointer] = []
    private var unregisterCallback: UnregisterCallback?
    private var stopDevice: StopDevice?
    private var trackingDevice: UnsafeMutableRawPointer?
    private var trackedTouchIDs: Set<Int32> = []
    private var needsTouchRebind = false
    private var initialPosition = MTPoint(x: 0, y: 0)
    private var active = false
    private var eligible = false
    private var cancelledUntilRelease = false
    private var cancelledTouchIDs: Set<Int32> = []
    private var scrollSuppressionRequested = false
    private var callbackGeneration: UInt = 0
    private var lastFrameUptime: UInt64 = 0
    private var lastRestartUptime: UInt64 = 0
    private var lastStartFailureLog: String?
    /// Regression hook: when set, replaces the system-wide idle query.
    var inputIdleSecondsOverride: (() -> Double)?
    /// Regression hook: when set, replaces the stop/start rebuild.
    var livenessRestart: (() -> Void)?

    deinit {
        stop()
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return framework != nil
    }

    @discardableResult
    func start() -> Bool {
        stateLock.lock()
        let alreadyStarted = framework != nil
        stateLock.unlock()
        if alreadyStarted { return true }

        guard let library = Self.loadLibrary() else {
            logStartFailure("failed to load MultitouchSupport")
            return false
        }
        guard let createList: CreateList = symbol("MTDeviceCreateList", in: library),
              let register: RegisterCallback = symbol("MTRegisterContactFrameCallback", in: library),
              let unregister: UnregisterCallback = symbol("MTUnregisterContactFrameCallback", in: library),
              let startDevice: StartDevice = symbol("MTDeviceStart", in: library),
              let stopDevice: StopDevice = symbol("MTDeviceStop", in: library),
              let list = createList()?.takeRetainedValue() else {
            logStartFailure("MultitouchSupport symbols unavailable")
            return false
        }

        var discovered: [UnsafeMutableRawPointer] = []
        for index in 0..<CFArrayGetCount(list) {
            guard let device = CFArrayGetValueAtIndex(list, index) else { continue }
            discovered.append(UnsafeMutableRawPointer(mutating: device))
        }

        guard !discovered.isEmpty else {
            logStartFailure("no trackpad devices found")
            return false
        }
        stateLock.lock()
        framework = library
        devices = discovered
        unregisterCallback = unregister
        self.stopDevice = stopDevice
        callbackGeneration &+= 1
        lastStartFailureLog = nil
        stateLock.unlock()
        for device in discovered {
            Self.registryLock.lock()
            Self.owners[device] = self
            Self.registryLock.unlock()
            register(device, Self.callback)
            startDevice(device, 0)
        }
        Self.log("monitoring \(discovered.count) trackpad device(s)")
        return true
    }

    private static func loadLibrary() -> UnsafeMutableRawPointer? {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let handle = libraryHandle { return handle }
        let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
        libraryHandle = handle
        return handle
    }

    private func logStartFailure(_ message: String) {
        stateLock.lock()
        let changed = lastStartFailureLog != message
        lastStartFailureLog = message
        stateLock.unlock()
        if changed { Self.log(message) }
    }

    /// Discard queued input and wait for the current contacts to lift before recognizing another gesture.
    func cancelCurrentGesture() {
        stateLock.lock()
        callbackGeneration &+= 1
        active = false
        eligible = false
        cancelledUntilRelease = trackingDevice != nil
        cancelledTouchIDs = trackingDevice != nil ? trackedTouchIDs : []
        setScrollSuppressionLocked(false)
        stateLock.unlock()
    }

    /// Periodic self-check: if the system is producing touch-like input but no contact
    /// frame has arrived for a while, the registration has gone stale and is rebuilt.
    /// Skipped while a gesture is in progress.
    func performLivenessCheck() {
        let now = DispatchTime.now().uptimeNanoseconds
        stateLock.lock()
        guard framework != nil, trackingDevice == nil, !active, lastFrameUptime != 0 else {
            stateLock.unlock()
            return
        }
        let frameAge = now &- lastFrameUptime
        stateLock.unlock()
        guard frameAge > Self.livenessThresholdNanos,
              lastRestartUptime == 0 || now &- lastRestartUptime > Self.restartSpacingNanos else {
            return
        }

        let idleSeconds = inputIdleSecondsOverride?() ?? Self.systemInputIdleSeconds()
        guard idleSeconds < Double(Self.livenessThresholdNanos) / 1_000_000_000 else { return }

        stateLock.lock()
        lastRestartUptime = now
        stateLock.unlock()
        Self.log(String(
            format: "contact stream silent for %.0fs while input is active — re-registering",
            Double(frameAge) / 1_000_000_000
        ))
        if let restart = livenessRestart {
            restart()
        } else {
            stop()
            if !start() { Self.log("re-registration failed; the availability poll will retry") }
        }
    }

    private static func systemInputIdleSeconds() -> Double {
        [
            CGEventType.scrollWheel,      // two-finger scrolling
            CGEventType.mouseMoved,       // pointer movement
            CGEventType.leftMouseDragged
        ]
        .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
        .min() ?? .infinity
    }

    func stop() {
        stateLock.lock()
        let currentDevices = devices
        let unregister = unregisterCallback
        let stopDevice = stopDevice
        let shouldCancel = active
        framework = nil
        devices = []
        unregisterCallback = nil
        self.stopDevice = nil
        callbackGeneration &+= 1
        resetLocked()
        if shouldCancel {
            deliver(generation: callbackGeneration) { $0.onFinish?(false) }
        }
        stateLock.unlock()

        for device in currentDevices {
            unregister?(device, Self.callback)
            stopDevice?(device)
            Self.registryLock.lock()
            Self.owners.removeValue(forKey: device)
            Self.registryLock.unlock()
        }
        Self.log("monitoring stopped")
    }

    private func handle(device: UnsafeMutableRawPointer, touches: UnsafeMutablePointer<MTTouch>?, count: Int) {
        stateLock.lock()
        guard framework != nil else {
            stateLock.unlock()
            return
        }
        lastFrameUptime = DispatchTime.now().uptimeNanoseconds
        if count == 0 {
            let shouldCommit = active
            let wasTracking = trackingDevice == device
            if wasTracking { resetLocked() }
            if shouldCommit && wasTracking {
                deliver(generation: callbackGeneration) { $0.onFinish?(true) }
            }
            stateLock.unlock()
            return
        }

        guard trackingDevice == nil || trackingDevice == device else {
            stateLock.unlock()
            return
        }
        if cancelledUntilRelease {
            // The cancelled gesture's contacts are ignored until they lift. But if a
            // fully fresh set of touch IDs arrives, the lift frame was lost (contacts
            // ended while cancellation was still being processed) — treat it as a new
            // gesture instead of staying cancelled forever.
            let freshContacts = count >= 3 && touches != nil && Set(
                UnsafeBufferPointer(start: touches!, count: count).map(\.identifier)
            ).isDisjoint(with: cancelledTouchIDs)
            guard freshContacts else {
                stateLock.unlock()
                return
            }
            Self.log("cancelled gesture superseded by a fresh set of contacts")
            resetLocked()
        }
        guard count >= 3, let touches else {
            if trackingDevice == device {
                needsTouchRebind = true
                setScrollSuppressionLocked(false)
            }
            stateLock.unlock()
            return
        }

        let allTouches = Array(UnsafeBufferPointer(start: touches, count: count))
        let trackedTouches: [MTTouch]
        let rebinding = trackingDevice == device && needsTouchRebind
        if trackingDevice == nil || rebinding {
            trackedTouches = Array(allTouches.prefix(3))
            trackingDevice = device
            trackedTouchIDs = Set(trackedTouches.map(\.identifier))
            needsTouchRebind = false
        } else {
            trackedTouches = allTouches.filter { trackedTouchIDs.contains($0.identifier) }
            guard trackedTouches.count == 3 else {
                needsTouchRebind = true
                setScrollSuppressionLocked(false)
                stateLock.unlock()
                return
            }
        }
        let position = MTPoint(
            x: trackedTouches.reduce(0) { $0 + $1.normalized.position.x } / 3,
            y: trackedTouches.reduce(0) { $0 + $1.normalized.position.y } / 3
        )
        if rebinding {
            initialPosition = position
            setScrollSuppressionLocked(active)
            stateLock.unlock()
            return
        }
        if !eligible {
            initialPosition = position
            active = false
            eligible = true
            stateLock.unlock()
            return
        }

        let deltaX = position.x - initialPosition.x
        let deltaY = position.y - initialPosition.y
        let horizontalDistance = active ? Self.horizontalStepDistance : Self.horizontalActivationDistance
        let horizontalProgress = abs(deltaX) / horizontalDistance
        let direction: HotkeyManager.Direction
        if !active {
            let verticalProgress = abs(deltaY) / Self.verticalActivationDistance
            guard horizontalProgress >= 1, horizontalProgress >= verticalProgress else {
                stateLock.unlock()
                return
            }
            direction = deltaX < 0 ? .left : .right
        } else {
            let verticalProgress = abs(deltaY) / Self.verticalStepDistance
            guard max(horizontalProgress, verticalProgress) >= 1 else {
                stateLock.unlock()
                return
            }
            if horizontalProgress >= verticalProgress {
                direction = deltaX < 0 ? .left : .right
            } else {
                direction = deltaY < 0 ? .down : .up
            }
        }
        let isBeginning = !active
        active = true
        initialPosition = position
        if isBeginning {
            scrollSuppressionRequested = true
            deliver(generation: callbackGeneration) {
                $0.onBegin?(direction)
                $0.onTrackingChanged?(true)
            }
        } else {
            deliver(generation: callbackGeneration) { $0.onStep?(direction) }
        }
        stateLock.unlock()
    }

    private func setScrollSuppressionLocked(_ suppressed: Bool) {
        guard scrollSuppressionRequested != suppressed else { return }
        scrollSuppressionRequested = suppressed
        deliver(generation: callbackGeneration) { $0.onTrackingChanged?(suppressed) }
    }

    private func deliver(generation: UInt, _ action: @escaping (TrackpadGestureManager) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let current = self.callbackGeneration
            self.stateLock.unlock()
            guard current == generation else { return }
            action(self)
        }
    }

    private func resetLocked() {
        setScrollSuppressionLocked(false)
        trackingDevice = nil
        trackedTouchIDs = []
        needsTouchRebind = false
        initialPosition = MTPoint(x: 0, y: 0)
        active = false
        eligible = false
        cancelledUntilRelease = false
        cancelledTouchIDs = []
    }

    private static func log(_ message: String) {
        NSLog("Switch: trackpad \(message)")
    }

    private func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer) -> T? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
