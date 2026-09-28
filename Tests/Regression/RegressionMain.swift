import AppKit

func drainRegressionEvents() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
}

func regressionWindows(_ count: Int) -> [WindowInfo] {
    (0..<count).map {
        WindowInfo(id: CGWindowID($0 + 1), pid: 12345, appName: "Fixture",
                   bounds: .zero, title: "Window \($0 + 1)")
    }
}

@main
struct RegressionMain {
    @MainActor static func main() {
        _ = NSApplication.shared
        // The standalone executable has its own unique defaults domain, separate from Switch.app.
        let domain = ProcessInfo.processInfo.processName
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let prefs = SwitchPreferences.shared
        prefs.showThumbnails = false
        prefs.verticalList = false
        prefs.automaticGridColumns = false
        prefs.gridColumns = 4
        prefs.includeWindowlessApps = false
        prefs.hideMinimizedWindows = false
        prefs.titleExclusions = []
        prefs.pinnedBundleIDs = []
        prefs.threeFingerSwitching = false

        TrackpadGestureManager.runRegressionTests()
        SwitchModel.runRegressionTests()
        HotkeyManager.runRegressionTests()
        AppDelegate.runRegressionTests()
        print("All gesture, navigation, scroll, session and layout regressions passed.")
    }
}
