extension TrackpadGestureManager {
    var cancelledUntilReleaseForRegression: Bool { cancelledUntilRelease }
    var runningForRegression: Bool { framework != nil }

    func regressionAttachDevice() {
        precondition(framework == nil)
        // Own a valid dlopen handle without loading MultitouchSupport or touching real devices.
        framework = dlopen(nil, RTLD_NOW)
        precondition(framework != nil)
        devices = [UnsafeMutableRawPointer(bitPattern: 1)!]
    }

    func regressionFrame(_ ids: [Int32], x: Float, y: Float = 0.5, extraX: Float? = nil) {
        var contacts = ids.map { id in
            let point = MTPoint(x: id == 4 ? (extraX ?? x) : x, y: y)
            let vector = MTVector(position: point, velocity: MTPoint(x: 0, y: 0))
            return MTTouch(frame: 0, timestamp: 0, identifier: id, state: 4,
                           unknown1: 0, unknown2: 0, normalized: vector, size: 0,
                           unknown3: 0, angle: 0, majorAxis: 0, minorAxis: 0,
                           millimeters: vector, unknown4: (0, 0), density: 0)
        }
        contacts.withUnsafeMutableBufferPointer {
            handle(device: UnsafeMutableRawPointer(bitPattern: 1)!, touches: $0.baseAddress, count: ids.count)
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
        precondition(events.isEmpty, "Frames arriving after stop must be ignored")
        print("PASS: trackpad activation, pause/resume, fourth finger, cancellation and queued callbacks")
    }
}
