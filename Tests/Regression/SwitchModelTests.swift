extension SwitchModel {
    @MainActor static func runRegressionTests() {
        let model = SwitchModel()
        model.windows = regressionWindows(5)
        model.gridColumnCount = 4
        let cases: [(HotkeyManager.Direction, Bool, [Int])] = [
            (.down, false, [4, 1, 2, 3, 4]),
            (.up, false, [0, 1, 2, 3, 0]),
            (.left, false, [0, 0, 1, 2, 4]),
            (.right, false, [1, 2, 3, 3, 4]),
            (.down, true, [4, 0, 1, 2, 3]),
            (.up, true, [1, 2, 3, 4, 0])
        ]
        for (direction, wrap, expected) in cases {
            for index in expected.indices {
                model.selected = index
                model.navigate(direction: direction, wrapHorizontal: wrap, wrapVertical: wrap)
                precondition(model.selected == expected[index], "Wrong \(direction) destination from \(index), wrap=\(wrap)")
            }
        }
        model.windows = regressionWindows(6)
        model.selected = 2
        precondition(!model.navigate(direction: .down, wrapHorizontal: false, wrapVertical: false))
        precondition(model.selected == 2, "Missing last-row columns must remain at the boundary")
        model.selected = 1
        model.navigate(direction: .down, wrapHorizontal: false, wrapVertical: false)
        precondition(model.selected == 5)
        model.navigate(direction: .up, wrapHorizontal: false, wrapVertical: false)
        precondition(model.selected == 1, "Up/down must preserve the column")

        model.windows = []
        model.pendingGestureDirections = [.right]
        model.navigate(direction: .right, wrapHorizontal: false, wrapVertical: false)
        model.navigate(direction: .down, wrapHorizontal: false, wrapVertical: false)
        model.navigate(direction: .left, wrapHorizontal: false, wrapVertical: false)
        let snapshot: (Int) -> WindowStore.Snapshot = { count in
            .init(windows: .init(activeSpace: regressionWindows(count), crossSpace: [], spaceRepresentatives: []),
                  takenAt: Date())
        }
        model.apply(snapshot: snapshot(0), initial: true)
        precondition(model.pendingGestureDirections?.count == 4, "An empty snapshot must preserve queued input")
        model.apply(snapshot: snapshot(8), initial: true)
        precondition(model.selected == 5, "Loading must replay right, right, down, left in order")
        precondition(model.pendingGestureDirections == nil)
        model.pendingGestureDirections = [.right, .right]
        model.cancel()
        precondition(model.pendingGestureDirections == nil, "Cancellation must discard loading input")
        model.windows = regressionWindows(5)
        model.selected = 0
        model.navigate(direction: .right)
        precondition(model.selected == 1, "Old gesture input must not affect a later keyboard session")
        print("PASS: incomplete rows, keyboard wrapping and navigation during snapshot loading")
    }
}
