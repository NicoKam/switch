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

    /// A registration can go silently stale (observed after system gesture
    /// handling, input re-enumeration, and DarkWake): no contact frames are
    /// delivered even though the trackpad is in use. When this much time passes
    /// without frames, the registration is rebuilt on a fresh device discovery.
    private static let livenessThresholdNanos: UInt64 = 30 * 1_000_000_000
    /// Rebuild spacing doubles with each consecutive unsuccessful rebuild, capped here.
    private static let baseRestartSpacingNanos: UInt64 = 60 * 1_000_000_000
    private static let maxRestartSpacingNanos: UInt64 = 600 * 1_000_000_000
    /// MTDeviceStop tears down the device thread, and crashes inside
    /// MultitouchSupport when the teardown releases the last reference to the
    /// device: the framework then re-stops an already-stopped port. Registration
    /// therefore holds one strong reference per device for the process lifetime,
    /// so the thread-exit release never reaches zero (validated: eight live-frame
    /// cycles of unregister → 2s silence → stop with the extra reference, no
    /// crash, every subsequent registration received frames). Skipping the stop
    /// entirely is worse: abandoned device threads keep polling and eventually
    /// starve the kernel's multitouch queue for every client.
    private static let retirementDelayNanos: UInt64 = 2 * 1_000_000_000

    // The registry captures an epoch before entering handle(). Removing an owner
    // cannot revoke a callback that already captured it, so handle validates it too.
    private final class DeviceRegistration {
        weak var owner: TrackpadGestureManager?
        let epoch: UInt
        // Protected by registryLock, including callbacks waiting for stateLock.
        var inFlight = 0

        init(owner: TrackpadGestureManager, epoch: UInt) {
            self.owner = owner
            self.epoch = epoch
        }
    }

    private struct DeviceHealth {
        let registration: DeviceRegistration
        let startedAtUptime: UInt64
        var lastFrameUptime: UInt64 = 0
        var lastFrameLogUptime: UInt64 = 0

        func frameAge(at now: UInt64) -> UInt64? {
            let reference = lastFrameUptime != 0 ? lastFrameUptime : startedAtUptime
            guard reference != 0, now >= reference else { return nil }
            return now - reference
        }
    }

    private static let callback: ContactCallback = { device, touches, count, _, _ in
        guard let device else { return 0 }
        registryLock.lock()
        guard let registration = owners[device], let owner = registration.owner else {
            registryLock.unlock()
            return 0
        }
        registration.inFlight += 1
        registryLock.unlock()
        defer {
            registryLock.lock()
            registration.inFlight -= 1
            registryLock.unlock()
        }
        owner.handle(
            device: device,
            registration: registration,
            touches: touches?.assumingMemoryBound(to: MTTouch.self),
            count: Int(count)
        )
        return 0
    }
    private static let registryLock = NSLock()
    private static var owners: [UnsafeMutableRawPointer: DeviceRegistration] = [:]
    // Neither the library nor the extra device references are released during the
    // process lifetime: teardown must never enter the framework's final-release path.
    private static var libraryHandle: UnsafeMutableRawPointer?
    private static var keepAliveDevices: [AnyObject] = []

    private struct RetiringDevice {
        var device: UnsafeMutableRawPointer
        var registration: DeviceRegistration
        var unregisteredAtNanos: UInt64
    }

    private let stateLock = NSLock()
    // framework doubles as the enabled flag: while nil, contact frames are ignored.
    private var framework: UnsafeMutableRawPointer?
    private var devices: [UnsafeMutableRawPointer] = []
    private var deviceHealth: [UnsafeMutableRawPointer: DeviceHealth] = [:]
    private var retiringDevices: [RetiringDevice] = []
    private var registerCallback: RegisterCallback?
    private var unregisterCallback: UnregisterCallback?
    private var startDeviceCallback: StartDevice?
    private var stopDeviceCallback: StopDevice?
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
    private var lifecycleCleanupPending = false
    private var lastRestartUptime: UInt64 = 0
    private var consecutiveRestarts: UInt = 0
    private var lastStartFailureLog: String?
    /// Regression hook: when set, replaces the rediscovery rebuild.
    var livenessRestart: (() -> Void)?

    deinit {
        stop()
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return framework != nil
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

    @discardableResult
    func start() -> Bool {
        stateLock.lock()
        let frameworkLoaded = framework != nil
        let cachedDevices = devices
        stateLock.unlock()
        // framework != nil with no devices means a rebuild was interrupted before
        // discovery succeeded (rediscoverDevices empties the list first): fall
        // through and discover again instead of short-circuiting into nothing.
        if frameworkLoaded && !cachedDevices.isEmpty { return true }

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
            let pointer = UnsafeMutableRawPointer(mutating: device)
            guard !discovered.contains(pointer) else { continue }
            Self.registryLock.lock()
            Self.keepAliveDevices.append(unsafeBitCast(pointer, to: AnyObject.self))
            Self.registryLock.unlock()
            discovered.append(pointer)
        }

        guard !discovered.isEmpty else {
            logStartFailure("no trackpad devices found")
            return false
        }
        stateLock.lock()
        framework = library
        devices = discovered
        registerCallback = register
        unregisterCallback = unregister
        startDeviceCallback = startDevice
        stopDeviceCallback = stopDevice
        callbackGeneration &+= 1
        let now = DispatchTime.now().uptimeNanoseconds
        deviceHealth = Dictionary(uniqueKeysWithValues: discovered.map { device in
            (device, DeviceHealth(
                registration: DeviceRegistration(owner: self, epoch: callbackGeneration),
                startedAtUptime: now
            ))
        })
        let registrations = deviceHealth
        lastStartFailureLog = nil
        stateLock.unlock()
        for device in discovered {
            Self.registryLock.lock()
            Self.owners[device] = registrations[device]!.registration
            Self.registryLock.unlock()
            register(device, Self.callback)
            startDevice(device, 0)
        }
        Self.log("monitoring \(discovered.count) trackpad device(s), epoch=\(callbackGeneration), retained=\(Self.retainedDeviceCount)")
        for device in discovered {
            Self.log("registered device=\(device) epoch=\(registrations[device]!.registration.epoch)")
        }
        return true
    }

    /// Never dlclose: the library stays mapped for the process lifetime because
    /// dlclose while a contact callback is in flight on a device thread would crash.
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

    /// Lifecycle cleanup is queued under stateLock, before any new input. It must
    /// survive later registration generations; filtering it like input would leave
    /// AppDelegate's picker session and global scroll suppression behind.
    private func terminateGestureLocked(reason: String) {
        callbackGeneration &+= 1
        let wasActive = active
        let wasSuppressed = scrollSuppressionRequested
        resetLocked(notifyScrollSuppression: false)
        if !lifecycleCleanupPending {
            lifecycleCleanupPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                self.lifecycleCleanupPending = false
                self.stateLock.unlock()
                self.onTrackingChanged?(false)
                self.onFinish?(false)
            }
        }
        Self.log("session cancelled: reason=\(reason) active=\(wasActive) suppressed=\(wasSuppressed) generation=\(callbackGeneration)")
    }

    /// Suspend recognition; the poll continues draining the retirement queue.
    func stop() {
        stateLock.lock()
        let currentDevices = devices
        let health = deviceHealth
        let unregister = unregisterCallback
        let wasEnabled = framework != nil
        framework = nil
        devices = []
        deviceHealth = [:]
        if wasEnabled {
            terminateGestureLocked(reason: "monitoring disabled")
        }
        lastRestartUptime = 0
        consecutiveRestarts = 0
        stateLock.unlock()

        queueForRetirement(currentDevices, health: health, unregister: unregister)
        if wasEnabled {
            Self.log("callbacks unregistered (\(currentDevices.count) device(s) queued for retirement)")
        }
    }

    /// Full discovery on fresh objects; live gestures defer it, stale ones are cancelled.
    func rediscoverDevices() {
        stateLock.lock()
        guard framework != nil else {
            stateLock.unlock()
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if let trackingDevice,
           let age = deviceHealth[trackingDevice]?.frameAge(at: now),
           age <= Self.livenessThresholdNanos {
            stateLock.unlock()
            return
        }
        let oldDevices = devices
        let health = deviceHealth
        let unregister = unregisterCallback
        devices = []
        deviceHealth = [:]
        terminateGestureLocked(reason: "device rediscovery")
        stateLock.unlock()

        queueForRetirement(oldDevices, health: health, unregister: unregister)
        Self.log("rediscovering trackpad devices (\(oldDevices.count) retired)")
        _ = start()
    }

    private func queueForRetirement(
        _ devicesToRetire: [UnsafeMutableRawPointer],
        health: [UnsafeMutableRawPointer: DeviceHealth],
        unregister: UnregisterCallback?
    ) {
        for device in devicesToRetire {
            guard let registration = health[device]?.registration else { continue }
            // Revoke callback admission first. Callbacks already admitted retain the
            // old epoch and remain counted until they return, even while awaiting a lock.
            Self.registryLock.lock()
            if Self.owners[device] === registration {
                Self.owners.removeValue(forKey: device)
            }
            Self.registryLock.unlock()
            let unregisterStarted = DispatchTime.now().uptimeNanoseconds
            unregister?(device, Self.callback)
            // Each device gets a full quiet interval AFTER its own unregister returns.
            let unregisteredAt = DispatchTime.now().uptimeNanoseconds
            stateLock.lock()
            retiringDevices.append(RetiringDevice(
                device: device, registration: registration, unregisteredAtNanos: unregisteredAt
            ))
            stateLock.unlock()
            Self.log("queued retirement device=\(device) epoch=\(registration.epoch) unregisterMs=\((unregisteredAt - unregisterStarted) / 1_000_000) quietDelay=2s")
        }
    }

    private func drainRetiringDevices() {
        stateLock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        var due: [RetiringDevice] = []
        var waiting: [(UnsafeMutableRawPointer, UInt, Int)] = []
        Self.registryLock.lock()
        retiringDevices.removeAll { entry in
            guard now >= entry.unregisteredAtNanos,
                  now - entry.unregisteredAtNanos >= Self.retirementDelayNanos else { return false }
            guard entry.registration.inFlight == 0 else {
                waiting.append((entry.device, entry.registration.epoch, entry.registration.inFlight))
                return false
            }
            due.append(entry)
            return true
        }
        Self.registryLock.unlock()
        let stopDevice = stopDeviceCallback
        stateLock.unlock()

        for (device, epoch, count) in waiting {
            Self.log("retirement waiting device=\(device) epoch=\(epoch) inFlight=\(count)")
        }
        for entry in due {
            Self.log("stopping retired device=\(entry.device) epoch=\(entry.registration.epoch) quietMs=\((now - entry.unregisteredAtNanos) / 1_000_000)")
            stopDevice?(entry.device)
            Self.log("stopped retired device=\(entry.device) epoch=\(entry.registration.epoch)")
        }
    }

    /// Every discovered device, including a never-delivered registration, can
    /// trigger recovery. Mouse events cannot tell us whether a three-finger swipe
    /// was attempted. Full rediscovery shares a capped retry budget across devices.
    func performLivenessCheck() {
        drainRetiringDevices()

        stateLock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        guard framework != nil, !deviceHealth.isEmpty else {
            stateLock.unlock()
            return
        }
        let stale = deviceHealth.compactMap { device, health -> (UnsafeMutableRawPointer, UInt64)? in
            guard let age = health.frameAge(at: now), age > Self.livenessThresholdNanos else { return nil }
            return (device, age)
        }
        guard !stale.isEmpty else {
            stateLock.unlock()
            return
        }
        if let trackingDevice,
           let age = deviceHealth[trackingDevice]?.frameAge(at: now),
           age <= Self.livenessThresholdNanos {
            stateLock.unlock()
            return
        }
        // Unwind a dead session immediately, even if another rebuild is in backoff.
        if trackingDevice != nil || active || scrollSuppressionRequested {
            terminateGestureLocked(reason: "bound device stream stale")
        }
        let exponent = consecutiveRestarts == 0 ? 0 : min(consecutiveRestarts - 1, 4)
        let spacing = min(Self.baseRestartSpacingNanos << UInt64(exponent), Self.maxRestartSpacingNanos)
        guard lastRestartUptime == 0 || (now >= lastRestartUptime && now - lastRestartUptime > spacing) else {
            stateLock.unlock()
            return
        }
        lastRestartUptime = now
        consecutiveRestarts &+= 1
        let attempt = consecutiveRestarts
        let diagnostics = stale.map { device, age in
            "device=\(device) epoch=\(deviceHealth[device]!.registration.epoch) age=\(age / 1_000_000_000)s delivered=\(deviceHealth[device]!.lastFrameUptime != 0)"
        }.joined(separator: "; ")
        stateLock.unlock()
        Self.log("stale streams: \(diagnostics); recoveryAttempt=\(attempt) retrySpacing=\(spacing / 1_000_000_000)s")
        if let restart = livenessRestart {
            restart()
        } else {
            rediscoverDevices()
        }
    }

    private func handle(
        device: UnsafeMutableRawPointer, registration: DeviceRegistration,
        touches: UnsafeMutablePointer<MTTouch>?, count: Int
    ) {
        stateLock.lock()
        guard framework != nil, var health = deviceHealth[device],
              health.registration === registration else {
            stateLock.unlock()
            Self.log("ignored obsolete frame device=\(device) epoch=\(registration.epoch)")
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let firstFrame = health.lastFrameUptime == 0
        health.lastFrameUptime = now
        let heartbeat = count > 0 && now >= health.lastFrameLogUptime
            && now - health.lastFrameLogUptime > 1_000_000_000
        if heartbeat { health.lastFrameLogUptime = now }
        deviceHealth[device] = health
        // A busy peer must not repeatedly reset retries for a device that has
        // never recovered. Declare the new registration set healthy only once
        // every device has delivered a frame.
        if deviceHealth.values.allSatisfy({ $0.lastFrameUptime != 0 }) {
            if consecutiveRestarts != 0 {
                Self.log("all registered devices delivered frames; recovery backoff reset")
            }
            consecutiveRestarts = 0
            lastRestartUptime = 0
        }
        if firstFrame {
            Self.log("first frame device=\(device) epoch=\(registration.epoch) count=\(count)")
        }
        if heartbeat {
            Self.dbgLog("frames: device=\(device) epoch=\(registration.epoch) count=\(count) tracking=\(trackingDevice == device) active=\(active) cancelled=\(cancelledUntilRelease)")
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

    private func resetLocked(notifyScrollSuppression: Bool = true) {
        if notifyScrollSuppression {
            setScrollSuppressionLocked(false)
        } else {
            scrollSuppressionRequested = false
        }
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
        dbgLog(message)
    }

    /// File-based diagnostics: NSLog does not surface in the unified log for this
    /// app, and gesture failures have been invisible without this record. The pid
    /// separates app noise from regression-test noise sharing the file.
    private static let logLock = NSLock()
    static func dbgLog(_ message: String) {
        let line = "\(Date()) [pid \(ProcessInfo.processInfo.processIdentifier)] trackpad \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        logLock.lock()
        defer { logLock.unlock() }
        // O_APPEND also prevents the app and standalone probes from overwriting
        // one another's lines when they share this diagnostic file.
        let fd = open("/tmp/switch-gesture.log", O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written > 0 { offset += written }
                else if written < 0 && errno == EINTR { continue }
                else { break }
            }
        }
    }

    private static var retainedDeviceCount: Int {
        registryLock.lock()
        defer { registryLock.unlock() }
        return keepAliveDevices.count
    }

    private func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer) -> T? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
