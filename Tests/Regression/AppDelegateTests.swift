extension AppDelegate {
    @MainActor static func runRegressionTests() {
        let delegate = AppDelegate()
        let model = SwitchModel()
        let window = SwitcherWindow(model: model)
        let hotkey = HotkeyManager()
        let gesture = TrackpadGestureManager()
        delegate.model = model
        delegate.window = window
        delegate.hotkey = hotkey
        delegate.trackpadGesture = gesture
        delegate.observePickerLayout(model: model, window: window)
        drainRegressionEvents()
        model.visible = true
        model.windows = regressionWindows(4)
        drainRegressionEvents()
        precondition(model.gridColumnCount == 4,
                     "Initial layout: columns=\(model.gridColumnCount), windows=\(model.windows.count), preference=\(SwitchPreferences.shared.gridColumns), stored=\(String(describing: UserDefaults.standard.object(forKey: SwitchPreferences.gridColumnsKey)))")
        let oneRowHeight = model.panelSize.height
        model.windows = regressionWindows(5)
        drainRegressionEvents()
        precondition(model.panelSize.height > oneRowHeight, "Resize must read the newly published window count")
        model.windows = regressionWindows(4)
        drainRegressionEvents()
        precondition(model.panelSize.height == oneRowHeight, "Removing a window must shrink the panel")

        model.windows = regressionWindows(8)
        SwitchPreferences.shared.gridColumns = 6
        drainRegressionEvents()
        precondition(model.gridColumnCount == 6, "Column changes must read defaults after didSet")
        SwitchPreferences.shared.automaticGridColumns = true
        drainRegressionEvents()
        precondition(model.gridColumnCount == GridLayoutMetrics.columns(itemCount: 8, screen: SwitcherWindow.pickerScreen()))
        SwitchPreferences.shared.gridColumns = 3
        SwitchPreferences.shared.automaticGridColumns = false
        drainRegressionEvents()
        precondition(model.gridColumnCount == 3, "Disabling automatic columns must apply the latest manual count")

        gesture.regressionAttachDevice()
        gesture.regressionFrame([1, 2, 3], x: 0.5)
        gesture.regressionFrame([1, 2, 3], x: 0.55)
        drainRegressionEvents()
        delegate.trackpadGestureSessionActive = true
        hotkey.setScrollSuppressed(true)
        delegate.invalidateTrackpadGestureSession()
        precondition(!delegate.trackpadGestureSessionActive && !hotkey.regressionScrollIsSuppressed())
        precondition(gesture.cancelledUntilReleaseForRegression, "A replaced session must wait for the old contacts to lift")

        // Exercise the actual finish handler before a delayed preference subscriber can stop capture.
        SwitchPreferences.shared.threeFingerSwitching = false
        model.visible = true
        delegate.trackpadGestureSessionActive = true
        delegate.finishTrackpadGesture(commit: true)
        precondition(!model.visible && !delegate.trackpadGestureSessionActive,
                     "A queued finish after disabling the preference must cancel, never focus a window")
        precondition(!gesture.runningForRegression)
        delegate.beginTrackpadGesture(direction: .right)
        precondition(!model.visible && !delegate.trackpadGestureSessionActive, "A disabled gesture cannot open the picker")
        model.visible = true
        delegate.trackpadGestureSessionActive = true
        delegate.stepTrackpadGesture(direction: .right)
        precondition(!model.visible && !delegate.trackpadGestureSessionActive)
        model.cancel()
        print("PASS: snapshot resizing, current layout preferences and gesture session invalidation")
    }
}
