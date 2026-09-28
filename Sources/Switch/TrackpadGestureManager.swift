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
    private var scrollSuppressionRequested = false
    private var callbackGeneration: UInt = 0

    deinit {
        stop()
    }

    @discardableResult
    func start() -> Bool {
        stateLock.lock()
        let alreadyStarted = framework != nil
        stateLock.unlock()
        if alreadyStarted { return true }

        guard let library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else {
            return false
        }
        guard let createList: CreateList = symbol("MTDeviceCreateList", in: library),
              let register: RegisterCallback = symbol("MTRegisterContactFrameCallback", in: library),
              let unregister: UnregisterCallback = symbol("MTUnregisterContactFrameCallback", in: library),
              let startDevice: StartDevice = symbol("MTDeviceStart", in: library),
              let stopDevice: StopDevice = symbol("MTDeviceStop", in: library),
              let list = createList()?.takeRetainedValue() else {
            dlclose(library)
            return false
        }

        var discovered: [UnsafeMutableRawPointer] = []
        for index in 0..<CFArrayGetCount(list) {
            guard let device = CFArrayGetValueAtIndex(list, index) else { continue }
            discovered.append(UnsafeMutableRawPointer(mutating: device))
        }

        guard !discovered.isEmpty else {
            dlclose(library)
            return false
        }
        stateLock.lock()
        framework = library
        devices = discovered
        unregisterCallback = unregister
        self.stopDevice = stopDevice
        callbackGeneration &+= 1
        stateLock.unlock()
        for device in discovered {
            Self.registryLock.lock()
            Self.owners[device] = self
            Self.registryLock.unlock()
            register(device, Self.callback)
            startDevice(device, 0)
        }
        return true
    }

    /// Discard queued input and wait for the current contacts to lift before recognizing another gesture.
    func cancelCurrentGesture() {
        stateLock.lock()
        callbackGeneration &+= 1
        active = false
        eligible = false
        cancelledUntilRelease = trackingDevice != nil
        setScrollSuppressionLocked(false)
        stateLock.unlock()
    }

    func stop() {
        stateLock.lock()
        let handle = framework
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
        if let handle { dlclose(handle) }
    }

    private func handle(device: UnsafeMutableRawPointer, touches: UnsafeMutablePointer<MTTouch>?, count: Int) {
        stateLock.lock()
        guard framework != nil else {
            stateLock.unlock()
            return
        }
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
        guard !cancelledUntilRelease else {
            stateLock.unlock()
            return
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
    }

    private func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer) -> T? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
