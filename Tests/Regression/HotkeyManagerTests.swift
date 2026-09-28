extension HotkeyManager {
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
