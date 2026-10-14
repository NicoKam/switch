extension TrackpadGestureManager {
    var cancelledUntilReleaseForRegression: Bool { cancelledUntilRelease }
    var runningForRegression: Bool { framework != nil }
    var consecutiveRestartsForRegression: UInt { consecutiveRestarts }

    func regressionAttachDevice() {
        precondition(framework == nil)
        // Own a valid dlopen handle without loading MultitouchSupport or touching real devices.
        framework = dlopen(nil, RTLD_NOW)
        precondition(framework != nil)
        devices = [UnsafeMutableRawPointer(bitPattern: 1)!]
        callbackGeneration &+= 1
        deviceHealth = [devices[0]: DeviceHealth(
            registration: DeviceRegistration(owner: self, epoch: callbackGeneration),
            startedAtUptime: DispatchTime.now().uptimeNanoseconds
        )]
    }

    func regressionFrame(_ ids: [Int32], x: Float, y: Float = 0.5, extraX: Float? = nil, device: UnsafeMutableRawPointer? = nil) {
        let device = device ?? UnsafeMutableRawPointer(bitPattern: 1)!
        guard let registration = deviceHealth[device]?.registration else { return }
        var contacts = ids.map { id in
            let point = MTPoint(x: id == 4 ? (extraX ?? x) : x, y: y)
            let vector = MTVector(position: point, velocity: MTPoint(x: 0, y: 0))
            return MTTouch(frame: 0, timestamp: 0, identifier: id, state: 4,
                           unknown1: 0, unknown2: 0, normalized: vector, size: 0,
                           unknown3: 0, angle: 0, majorAxis: 0, minorAxis: 0,
                           millimeters: vector, unknown4: (0, 0), density: 0)
        }
        contacts.withUnsafeMutableBufferPointer {
            handle(device: device, registration: registration, touches: $0.baseAddress, count: ids.count)
        }
    }

    static func runRegressionTests() {
        let manager = TrackpadGestureManager()
        var events: [String] = []
        manager.onBegin = { events.append("begin:\($0)") }
        manager.onStep = { events.append("step:\($0)") }
        manager.onTrackingChanged = { events.append("tracking:\($0)") }
        manager.onFinish = { events.append("finish:\($0)") }
        manager.regressionAttachDevice()

        manager.regressionFrame([1, 2, 3], x: 0.5)
        manager.regressionFrame([1, 2, 3], x: 0.5, y: 0.7)
        manager.regressionFrame([1, 2], x: 0.5, y: 0.7)
        drainRegressionEvents()
        precondition(events.isEmpty, "Contacts and vertical motion must not activate or suppress scrolling")
        manager.regressionFrame([], x: 0.5)

        manager.regressionFrame([1, 2, 3], x: 0.5)
        manager.regressionFrame([1, 2, 3], x: 0.55)
        drainRegressionEvents()
        precondition(events == ["begin:right", "tracking:true"], "Begin must precede scroll suppression")
        manager.regressionFrame([1, 2], x: 0.55)
        drainRegressionEvents()
        precondition(events.last == "tracking:false", "Two-finger scrolling must resume")
        manager.regressionFrame([1, 2, 3], x: 0.8, y: 0.7)
        drainRegressionEvents()
        precondition(events.last == "tracking:true", "Rebinding resumes suppression without a jump")
        manager.regressionFrame([1, 2, 3], x: 0.84, y: 0.7)
        drainRegressionEvents()
        precondition(events.last == "step:right")
        let beforeFourthFinger = events
        manager.regressionFrame([4, 1, 2, 3], x: 0.84, y: 0.7, extraX: 0.1)
        drainRegressionEvents()
        precondition(events == beforeFourthFinger, "A fourth finger must not move the tracked centroid")
        manager.regressionFrame([1, 2, 3], x: 0.84, y: 0.6)
        manager.regressionFrame([], x: 0.84)
        drainRegressionEvents()
        precondition(Array(events.suffix(3)) == ["step:down", "tracking:false", "finish:true"])

        events = []
        manager.regressionFrame([1, 2, 3], x: 0.5)
        manager.regressionFrame([1, 2, 3], x: 0.55)
        manager.cancelCurrentGesture()
        manager.regressionFrame([1, 2, 3], x: 0.65)
        manager.regressionFrame([], x: 0.65)
        drainRegressionEvents()
        precondition(events == ["tracking:false"], "Cancellation must discard queued begin/steps/commit")
        events = []
        manager.regressionFrame([1, 2, 3], x: 0.5)
        manager.regressionFrame([1, 2, 3], x: 0.55)
        manager.regressionFrame([], x: 0.55)
        drainRegressionEvents()
        precondition(events == ["begin:right", "tracking:true", "tracking:false", "finish:true"],
                     "Normal lift must preserve a quick gesture's queued begin and commit")

        events = []
        manager.regressionFrame([1, 2, 3], x: 0.5)
        manager.regressionFrame([1, 2, 3], x: 0.55)
        manager.stop()
        drainRegressionEvents()
        precondition(events == ["tracking:false", "finish:false"], "Stop must invalidate queued activation")
        events = []
        manager.regressionAttachDevice()
        manager.regressionFrame([1, 2, 3], x: 0.5)
        manager.regressionFrame([1, 2, 3], x: 0.55)
        drainRegressionEvents()
        events = []
        manager.regressionFrame([], x: 0.55)
        manager.stop()
        drainRegressionEvents()
        precondition(!events.contains("finish:true"), "Stop must invalidate an already queued commit")
        manager.regressionFrame([1, 2, 3], x: 0.5)
        manager.regressionFrame([1, 2, 3], x: 0.55)
        drainRegressionEvents()
        precondition(events == ["tracking:false", "finish:false"], "Stop must cancel even a pending lift/commit; later frames are ignored")
        print("PASS: trackpad activation, pause/resume, fourth finger, cancellation and queued callbacks")

        // A cancelled gesture whose lift frame was lost (contacts ended while
        // cancellation was still being processed) must not wedge the manager:
        // a fully fresh set of touch IDs starts a new gesture without a count == 0 frame.
        events = []
        manager.regressionAttachDevice()
        manager.regressionFrame([1, 2, 3], x: 0.5)
        manager.regressionFrame([1, 2, 3], x: 0.55)
        manager.cancelCurrentGesture()
        manager.regressionFrame([1, 2, 3], x: 0.65)
        drainRegressionEvents()
        precondition(events == ["tracking:false"],
                     "The cancelled gesture's own contacts must stay ignored until they lift")
        events = []
        manager.regressionFrame([7, 8, 9], x: 0.5)
        manager.regressionFrame([7, 8, 9], x: 0.55)
        drainRegressionEvents()
        precondition(events == ["begin:right", "tracking:true"],
                     "Fresh contacts must start a new gesture without a lift frame")
        manager.regressionFrame([], x: 0.55)
        drainRegressionEvents()

        // Liveness: a silent contact stream must rebuild the registration without
        // requiring fresh input once the stream has delivered frames before — a
        // three-finger swipe produces no observable events at all. Recent frames
        // or a gesture in progress still suppress the restart.
        events = []
        var restartCount = 0
        manager.livenessRestart = { restartCount += 1 }
        manager.deviceHealth[manager.devices[0]]!.lastFrameUptime = DispatchTime.now().uptimeNanoseconds - 120 * 1_000_000_000
        manager.performLivenessCheck()
        precondition(restartCount == 1, "A stale delivered stream must rebuild even without observable input")
        manager.deviceHealth[manager.devices[0]]!.lastFrameUptime = DispatchTime.now().uptimeNanoseconds
        manager.performLivenessCheck()
        precondition(restartCount == 1, "A recent frame must suppress the restart")
        events = []
        manager.regressionFrame([1, 2, 3], x: 0.5)
        manager.regressionFrame([1, 2, 3], x: 0.55)
        drainRegressionEvents()
        precondition(events == ["begin:right", "tracking:true"], "Gesture must be active before the mid-gesture check")
        // A live gesture has fresh frames — the rebuild must leave it alone.
        manager.deviceHealth[manager.devices[0]]!.lastFrameUptime = DispatchTime.now().uptimeNanoseconds - 5 * 1_000_000_000
        manager.performLivenessCheck()
        precondition(restartCount == 1, "A gesture in progress must not be restarted")
        manager.regressionFrame([], x: 0.55)
        drainRegressionEvents()
        precondition(events == ["begin:right", "tracking:true", "tracking:false", "finish:true"],
                     "The mid-gesture contacts must still finish normally")

        // A gesture abandoned mid-flight by a dead stream (its lift frame never
        // arrived) must not block future checks: the state is dropped and the
        // rebuild proceeds.
        manager.regressionFrame([1, 2, 3], x: 0.5)
        manager.regressionFrame([1, 2, 3], x: 0.55)
        drainRegressionEvents()
        precondition(events.contains("begin:right"), "Gesture must be active before the abandoned check")
        manager.deviceHealth[manager.devices[0]]!.lastFrameUptime = DispatchTime.now().uptimeNanoseconds - 120 * 1_000_000_000
        manager.lastRestartUptime = DispatchTime.now().uptimeNanoseconds - 300 * 1_000_000_000
        manager.performLivenessCheck()
        precondition(restartCount == 2, "An abandoned mid-gesture stream must be rebuilt")
        precondition(!manager.cancelledUntilReleaseForRegression,
                     "Abandoning a gesture must clear the tracking state")
        manager.regressionFrame([], x: 0.55)
        drainRegressionEvents()

        // Receiving frames again resets the escalation; the next silent window
        // restarts at the base spacing and persistent silence doubles it, capped.
        precondition(manager.consecutiveRestartsForRegression == 0, "Frames must reset restart escalation")
        manager.lastRestartUptime = DispatchTime.now().uptimeNanoseconds - 300 * 1_000_000_000
        manager.deviceHealth[manager.devices[0]]!.lastFrameUptime = DispatchTime.now().uptimeNanoseconds - 120 * 1_000_000_000
        manager.performLivenessCheck()
        precondition(restartCount == 3, "A fresh silent window restarts at the base spacing")
        manager.lastRestartUptime = DispatchTime.now().uptimeNanoseconds
        manager.deviceHealth[manager.devices[0]]!.lastFrameUptime = DispatchTime.now().uptimeNanoseconds - 120 * 1_000_000_000
        manager.performLivenessCheck()
        precondition(restartCount == 3, "Retry spacing must delay the next restart")

        // A discovered device can be dead from launch. Even without observable
        // mouse input, the discovery time must trigger a bounded recovery attempt.
        manager.regressionFrame([], x: 0.55)
        drainRegressionEvents()
        manager.consecutiveRestarts = 0
        manager.deviceHealth[manager.devices[0]]!.lastFrameUptime = 0
        manager.deviceHealth[manager.devices[0]] = DeviceHealth(
            registration: manager.deviceHealth[manager.devices[0]]!.registration,
            startedAtUptime: DispatchTime.now().uptimeNanoseconds - 120 * 1_000_000_000
        )
        manager.lastRestartUptime = DispatchTime.now().uptimeNanoseconds - 300 * 1_000_000_000
        manager.performLivenessCheck()
        precondition(restartCount == 4, "A never-delivered discovered device must rebuild without mouse input")
        manager.performLivenessCheck()
        precondition(restartCount == 4, "A repeated zero-frame check must respect the retry spacing")
        manager.deviceHealth[manager.devices[0]]!.lastFrameUptime = 0
        manager.deviceHealth[manager.devices[0]] = DeviceHealth(
            registration: manager.deviceHealth[manager.devices[0]]!.registration, startedAtUptime: 0
        )
        manager.performLivenessCheck()
        precondition(restartCount == 4, "No time anchor yet must not rebuild")
        manager.stop()
        drainRegressionEvents()
        runLifecycleRegressionTests()
        print("PASS: trackpad liveness watchdog and cancelled-gesture recovery")
    }
}

extension TrackpadGestureManager {
    private static func runLifecycleRegressionTests() {
        let previousLibrary = libraryHandle
        let path = ProcessInfo.processInfo.environment["SWITCH_REGRESSION_MT_LIBRARY"]!
        libraryHandle = dlopen(path, RTLD_NOW)
        precondition(libraryHandle != nil, "The isolated mock MT library must load")
        defer { libraryHandle = previousLibrary }
        let setEmpty = unsafeBitCast(dlsym(libraryHandle!, "SwitchRegressionSetEmptyDiscovery")!,
                                    to: (@convention(c) (Int32) -> Void).self)
        let setDelay = unsafeBitCast(dlsym(libraryHandle!, "SwitchRegressionSetUnregisterDelay")!,
                                    to: (@convention(c) (Double) -> Void).self)
        let stopCount = unsafeBitCast(dlsym(libraryHandle!, "SwitchRegressionStopCount")!,
                                     to: (@convention(c) () -> Int32).self)
        let emit = unsafeBitCast(dlsym(libraryHandle!, "SwitchRegressionEmitFrame")!,
                                to: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32) -> Void).self)
        let nanos: UInt64 = 1_000_000_000
        func makeStale(_ manager: TrackpadGestureManager, _ device: UnsafeMutableRawPointer) {
            let old = manager.deviceHealth[device]!
            manager.deviceHealth[device] = DeviceHealth(
                registration: old.registration,
                startedAtUptime: DispatchTime.now().uptimeNanoseconds - 120 * nanos,
                lastFrameUptime: old.lastFrameUptime == 0 ? 0 : DispatchTime.now().uptimeNanoseconds - 120 * nanos
            )
        }
        do {
            let manager = TrackpadGestureManager()
            var events: [String] = []
            var sessionActive = false
            let hotkey = HotkeyManager()
            manager.onBegin = { events.append("begin:\($0)"); sessionActive = true }
            manager.onTrackingChanged = { events.append("tracking:\($0)"); hotkey.setScrollSuppressed($0) }
            manager.onFinish = { events.append("finish:\($0)"); sessionActive = false }
            precondition(manager.start())
            let bound = manager.devices[0], peer = manager.devices[1]
            manager.regressionFrame([1, 2, 3], x: 0.5, device: bound)
            manager.regressionFrame([1, 2, 3], x: 0.55, device: bound)
            drainRegressionEvents()
            precondition(events == ["begin:right", "tracking:true"])
            precondition(sessionActive && hotkey.regressionScrollIsSuppressed())
            makeStale(manager, bound)
            emit(peer, nil, 0) // A healthy peer must not mask the stale bound device.
            let oldEpoch = manager.deviceHealth[bound]!.registration
            manager.performLivenessCheck() // Actual retire -> discover -> register -> start.
            drainRegressionEvents()
            precondition(events == ["begin:right", "tracking:true", "tracking:false", "finish:false"],
                         "Rediscovery must release external suppression and cancel the old session exactly once")
            precondition(!manager.devices.contains(bound) && manager.trackingDevice == nil)
            precondition(!sessionActive && !hotkey.regressionScrollIsSuppressed(),
                         "Rediscovery must close the external session and stop swallowing real scroll events")
            manager.handle(device: bound, registration: oldEpoch, touches: nil, count: 0)
            precondition(manager.deviceHealth.values.allSatisfy { $0.lastFrameUptime == 0 },
                         "A retired device's late frame must not refresh the replacement registrations")
            events = []
            let replacement = manager.devices[0]
            manager.regressionFrame([7, 8, 9], x: 0.5, device: replacement)
            manager.regressionFrame([7, 8, 9], x: 0.55, device: replacement)
            manager.regressionFrame([], x: 0.55, device: replacement)
            // Rebuilding between lift and queued commit must cancel, never focus.
            manager.rediscoverDevices()
            drainRegressionEvents()
            precondition(events == ["tracking:false", "finish:false"],
                         "Rediscovery must invalidate queued input but preserve lifecycle cleanup")
            events = []
            manager.stop()
            precondition(manager.start())
            let resumed = manager.devices[0]
            manager.regressionFrame([10, 11, 12], x: 0.5, device: resumed)
            manager.regressionFrame([10, 11, 12], x: 0.55, device: resumed)
            drainRegressionEvents()
            precondition(events == ["tracking:false", "finish:false", "begin:right", "tracking:true"],
                         "Rapid stop/start must deliver cleanup before the new session's activation")
            precondition(sessionActive && hotkey.regressionScrollIsSuppressed())
            manager.stop()
            drainRegressionEvents()
        }
        do {
            let manager = TrackpadGestureManager()
            precondition(manager.start())
            let oldDevices = manager.devices
            oldDevices.forEach { makeStale(manager, $0) }
            manager.performLivenessCheck()
            precondition(manager.devices != oldDevices && manager.consecutiveRestarts == 1,
                         "Zero-frame discovered devices must recover without mouse input")
            let peer = manager.devices[1]
            emit(peer, nil, 0)
            precondition(manager.consecutiveRestarts == 1, "One healthy peer cannot reset a silent device's recovery budget")
            manager.lastRestartUptime = DispatchTime.now().uptimeNanoseconds - 90 * nanos
            makeStale(manager, manager.devices[0])
            let secondDevices = manager.devices
            manager.performLivenessCheck()
            precondition(manager.devices != secondDevices && manager.consecutiveRestarts == 2,
                         "First failed recovery retries after the base 60s interval")
            let thirdDevices = manager.devices
            thirdDevices.forEach { makeStale(manager, $0) }
            manager.lastRestartUptime = DispatchTime.now().uptimeNanoseconds - 90 * nanos
            manager.performLivenessCheck()
            precondition(manager.devices == thirdDevices, "Second failed recovery must respect 120s backoff")
            manager.devices.forEach { emit($0, nil, 0) }
            precondition(manager.consecutiveRestarts == 0 && manager.lastRestartUptime == 0,
                         "Recovery of every device resets backoff for the next independent stall")
            manager.stop()
            drainRegressionEvents()
        }
        do {
            let manager = TrackpadGestureManager()
            precondition(manager.start())
            let bound = manager.devices[0]
            manager.regressionFrame([1, 2, 3], x: 0.5, device: bound)
            makeStale(manager, manager.devices[1])
            let oldDevices = manager.devices
            manager.performLivenessCheck()
            manager.rediscoverDevices()
            precondition(manager.devices == oldDevices, "A peer stall/wake must not interrupt a fresh bound gesture")
            manager.regressionFrame([], x: 0.5, device: bound)
            manager.performLivenessCheck()
            precondition(manager.devices != oldDevices, "Peer recovery proceeds once the live gesture ends")
            manager.stop()
            drainRegressionEvents()
        }
        do {
            let manager = TrackpadGestureManager()
            precondition(manager.start())
            // Freeze an admitted callback between registry lookup and handle's lock.
            let device = manager.devices[0]
            let old = manager.deviceHealth[device]!.registration
            let done = DispatchSemaphore(value: 0)
            manager.stateLock.lock()
            DispatchQueue.global().async {
                _ = Self.callback(device, nil, 0, 0, 0)
                done.signal()
            }
            let deadline = Date().addingTimeInterval(2)
            var admitted = false
            repeat {
                Self.registryLock.lock()
                admitted = old.inFlight == 1
                Self.registryLock.unlock()
                if !admitted { Thread.sleep(forTimeInterval: 0.001) }
            } while !admitted && Date() < deadline
            precondition(admitted, "The callback must be counted even while waiting for stateLock")
            let fresh = DeviceRegistration(owner: manager, epoch: old.epoch &+ 1)
            manager.deviceHealth[device] = DeviceHealth(registration: fresh, startedAtUptime: DispatchTime.now().uptimeNanoseconds)
            Self.registryLock.lock()
            Self.owners[device] = fresh
            Self.registryLock.unlock()
            manager.stateLock.unlock()
            precondition(done.wait(timeout: .now() + 2) == .success)
            precondition(manager.deviceHealth[device]!.lastFrameUptime == 0 && old.inFlight == 0,
                         "An admitted old epoch must be rejected even if the pointer is currently registered")
            emit(device, nil, 0)
            precondition(manager.deviceHealth[device]!.lastFrameUptime != 0 && fresh.inFlight == 0,
                         "The current epoch must still accept frames and drain its callback count")
            manager.stop()
            drainRegressionEvents()
        }
        do {
            let manager = TrackpadGestureManager()
            precondition(manager.start())
            setEmpty(1)
            manager.rediscoverDevices()
            precondition(manager.isRunning && manager.devices.isEmpty)
            setEmpty(0)
            precondition(manager.start() && !manager.devices.isEmpty,
                         "Discovery must retry after an interrupted empty rebuild")
            manager.stop()
            drainRegressionEvents()
        }
        do {
            let manager = TrackpadGestureManager()
            precondition(manager.start())
            let before = stopCount()
            setDelay(1.1) // Two unregisters take >2s, exercising per-device clocks.
            manager.stop()
            setDelay(0)
            manager.performLivenessCheck()
            precondition(stopCount() == before,
                         "A slow unregister batch must not consume the post-unregister quiet delay")
            precondition(manager.retiringDevices[1].unregisteredAtNanos - manager.retiringDevices[0].unregisteredAtNanos >= nanos)
            let held = manager.retiringDevices[0].registration
            manager.retiringDevices = manager.retiringDevices.map {
                RetiringDevice(device: $0.device, registration: $0.registration,
                               unregisteredAtNanos: DispatchTime.now().uptimeNanoseconds - 3 * nanos)
            }
            Self.registryLock.lock()
            held.inFlight = 1
            Self.registryLock.unlock()
            manager.performLivenessCheck()
            precondition(stopCount() == before + 1 && manager.retiringDevices.count == 1,
                         "A device with an admitted callback must remain queued past the quiet delay")
            Self.registryLock.lock()
            held.inFlight = 0
            Self.registryLock.unlock()
            manager.performLivenessCheck()
            manager.performLivenessCheck()
            manager.stop()
            manager.performLivenessCheck()
            precondition(stopCount() == before + 2 && manager.retiringDevices.isEmpty,
                         "Disabled monitoring drains each device exactly once after callbacks return")
            drainRegressionEvents()
        }
        print("PASS: actual MT lifecycle, cancellation delivery, per-device health, epochs and safe retirement")
    }
}
