import AppKit
import Darwin

func drainRegressionEvents() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
}

func drainRegressionEvents(until condition: () -> Bool, timeout: TimeInterval = 2) {
    let deadline = Date().addingTimeInterval(timeout)
    repeat { drainRegressionEvents() } while !condition() && Date() < deadline
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
        setbuf(stdout, nil)
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

        L10n.runRegressionTests()
        AppDelegate.runLocalizationRegressionTests()
        TrackpadGestureManager.runRegressionTests()
        SwitchModel.runRegressionTests()
        HotkeyManager.runRegressionTests()
        AppDelegate.runRegressionTests()
        print("All localization, gesture, navigation, scroll, session and layout regressions passed.")
    }
}
