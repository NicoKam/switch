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

    private static let activationDistance: Float = 0.03375
    private static let stepDistance: Float = 0.04125
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
    private var initialPosition = MTPoint(x: 0, y: 0)
    private var horizontalStep = 0
    private var verticalStep = 0
    private var active = false
    private var eligible = false

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
            let pointer = UnsafeMutableRawPointer(mutating: device)
            Self.registryLock.lock()
            Self.owners[pointer] = self
            Self.registryLock.unlock()
            register(pointer, Self.callback)
            startDevice(pointer, 0)
            discovered.append(pointer)
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
        stateLock.unlock()
        return true
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
        resetLocked()
        stateLock.unlock()

        for device in currentDevices {
            unregister?(device, Self.callback)
            stopDevice?(device)
            Self.registryLock.lock()
            Self.owners.removeValue(forKey: device)
            Self.registryLock.unlock()
        }
        if let handle { dlclose(handle) }
        if !currentDevices.isEmpty { emitTrackingChanged(false) }
        if shouldCancel {
            DispatchQueue.main.async { [weak self] in self?.onFinish?(false) }
        }
    }

    private func handle(device: UnsafeMutableRawPointer, touches: UnsafeMutablePointer<MTTouch>?, count: Int) {
        stateLock.lock()
        if count == 0 {
            let shouldCommit = active
            let wasTracking = trackingDevice == device
            if wasTracking { resetLocked() }
            stateLock.unlock()
            if wasTracking { emitTrackingChanged(false) }
            if shouldCommit && wasTracking { emitFinish(commit: true) }
            return
        }

        guard trackingDevice == nil || trackingDevice == device else {
            stateLock.unlock()
            return
        }
        guard count == 3, let touches else {
            if trackingDevice == device { eligible = false }
            stateLock.unlock()
            return
        }

        let position = MTPoint(
            x: (touches[0].normalized.position.x + touches[1].normalized.position.x + touches[2].normalized.position.x) / 3,
            y: (touches[0].normalized.position.y + touches[1].normalized.position.y + touches[2].normalized.position.y) / 3
        )
        if trackingDevice == nil {
            trackingDevice = device
            initialPosition = position
            horizontalStep = 0
            verticalStep = 0
            active = false
            eligible = true
            stateLock.unlock()
            emitTrackingChanged(true)
            return
        }
        guard eligible else {
            stateLock.unlock()
            return
        }

        let deltaX = position.x - initialPosition.x
        let deltaY = position.y - initialPosition.y
        let targetStep: (Float) -> Int = { delta in
            let magnitude = abs(delta)
            guard magnitude >= Self.activationDistance else { return 0 }
            let steps = 1 + Int((magnitude - Self.activationDistance) / Self.stepDistance)
            return delta < 0 ? -steps : steps
        }
        var targetHorizontal = targetStep(deltaX)
        var targetVertical = targetStep(deltaY)
        var beginDirection: HotkeyManager.Direction?
        var steps: [HotkeyManager.Direction] = []

        if !active {
            guard targetHorizontal != 0 || targetVertical != 0 else {
                stateLock.unlock()
                return
            }
            active = true
            if abs(deltaX) >= abs(deltaY) {
                horizontalStep = targetHorizontal > 0 ? 1 : -1
                beginDirection = horizontalStep < 0 ? .left : .right
                initialPosition.y = position.y
                targetVertical = 0
            } else {
                verticalStep = targetVertical > 0 ? 1 : -1
                beginDirection = verticalStep < 0 ? .down : .up
                initialPosition.x = position.x
                targetHorizontal = 0
            }
        }

        while horizontalStep != targetHorizontal {
            if horizontalStep < targetHorizontal {
                horizontalStep += 1
                steps.append(.right)
            } else {
                horizontalStep -= 1
                steps.append(.left)
            }
        }
        while verticalStep != targetVertical {
            if verticalStep < targetVertical {
                verticalStep += 1
                steps.append(.up)
            } else {
                verticalStep -= 1
                steps.append(.down)
            }
        }
        stateLock.unlock()

        if let beginDirection {
            DispatchQueue.main.async { [weak self] in self?.onBegin?(beginDirection) }
        }
        for direction in steps {
            DispatchQueue.main.async { [weak self] in self?.onStep?(direction) }
        }
    }

    private func emitTrackingChanged(_ tracking: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onTrackingChanged?(tracking) }
    }

    private func emitFinish(commit: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onFinish?(commit) }
    }

    private func resetLocked() {
        trackingDevice = nil
        initialPosition = MTPoint(x: 0, y: 0)
        horizontalStep = 0
        verticalStep = 0
        active = false
        eligible = false
    }

    private func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer) -> T? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
