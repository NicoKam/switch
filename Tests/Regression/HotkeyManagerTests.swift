extension HotkeyManager {
    @MainActor static func runUpstreamRegressionTests() {
        let prefs = SwitchPreferences.shared
        let apps = prefs.passthroughApps
        let reverse = prefs.backtickReverses
        let homeRow = prefs.homeRowSelection
        let vim = prefs.vimNavigation
        let filter = prefs.typeToFilter
        defer {
            prefs.passthroughApps = apps; prefs.backtickReverses = reverse
            prefs.homeRowSelection = homeRow; prefs.vimNavigation = vim; prefs.typeToFilter = filter
        }
        let hotkey = HotkeyManager()
        hotkey.frontmostBundleID = "regression.remote.desktop"
        prefs.passthroughApps = ["regression.remote.desktop"]
        let tab = CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true)!
        tab.flags = .maskCommand
        precondition(hotkey.handle(type: .keyDown, event: tab) != nil && !hotkey.isArmed,
                     "A frontmost pass-through app must receive the opening hotkey")
        prefs.passthroughApps = []
        precondition(hotkey.handle(type: .keyDown, event: tab) == nil && hotkey.isArmed)
        prefs.passthroughApps = ["regression.remote.desktop"]
        var advances: [Bool] = []
        hotkey.onAdvance = { advances.append($0) }
        prefs.backtickReverses = true
        let backtick = CGEvent(keyboardEventSource: nil, virtualKey: 50, keyDown: true)!
        backtick.flags = .maskCommand
        precondition(hotkey.handle(type: .keyDown, event: backtick) == nil)
        drainRegressionEvents(until: { advances.count == 1 })
        precondition(advances == [true], "Reverse navigation must work after cycling onto a pass-through app")
        hotkey.setScrollSuppressed(true)
        precondition(hotkey.regressionScrollIsSuppressed(), "New hotkey handling cannot bypass gesture scroll interception")
        hotkey.setScrollSuppressed(false)
        prefs.homeRowSelection = true
        var picked: Int?
        hotkey.onPickSelectOnly = { picked = $0 }
        let letter = CGEvent(keyboardEventSource: nil, virtualKey: 2, keyDown: true)!
        letter.flags = .maskCommand
        var code: UniChar = 100 // d: third window
        letter.keyboardSetUnicodeString(stringLength: 1, unicodeString: &code)
        precondition(hotkey.handle(type: .keyDown, event: letter) == nil)
        drainRegressionEvents(until: { picked != nil })
        precondition(picked == 2)
        hotkey.clearArmed()
        print("PASS pass-through activation, reverse/home-row keys and existing gesture scroll interception")
    }

    func regressionScrollIsSuppressed() -> Bool {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                            wheel1: 10, wheel2: 0, wheel3: 0)!
        return handle(type: .scrollWheel, event: event) == nil
    }

    static func runRegressionTests() {
        let hotkey = HotkeyManager()
        precondition(!hotkey.regressionScrollIsSuppressed())
        hotkey.setScrollSuppressed(true)
        precondition(hotkey.regressionScrollIsSuppressed())
        hotkey.setScrollSuppressed(false)
        precondition(!hotkey.regressionScrollIsSuppressed())
        hotkey.setScrollSuppressed(true)
        hotkey.setSuspended(true)
        precondition(!hotkey.regressionScrollIsSuppressed(), "Recording must leave normal scrolling available")
        print("PASS: actual scroll event interception")
    }
}
