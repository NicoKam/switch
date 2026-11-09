extension SwitchPreferences {
    @MainActor static func runUpstreamRegressionTests() {
        let defaults = UserDefaults.standard
        let keys = [thumbnailHeightKey, panelWidthScaleKey, threeFingerSwitchingKey,
                    automaticGridColumnsKey, L10n.languageKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(195.0, forKey: thumbnailHeightKey)
        defaults.removeObject(forKey: panelWidthScaleKey)
        defaults.set(true, forKey: threeFingerSwitchingKey)
        defaults.set(true, forKey: automaticGridColumnsKey)
        defaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: L10n.languageKey)
        let migrated = SwitchPreferences()
        precondition(migrated.panelWidthScale == 1.5, "Existing panel scale must survive the width setting migration")
        precondition(migrated.threeFingerSwitching && migrated.automaticGridColumns)
        precondition(migrated.language == .simplifiedChinese && migrated.thumbnailHeight == 195)
        defaults.set(1.25, forKey: panelWidthScaleKey)
        let restored = SwitchPreferences()
        precondition(restored.panelWidthScale == 1.25, "Reopening cannot replace a saved width with thumbnail scale")
        restored.homeRowSelection = true
        precondition(!restored.typeToFilter && !restored.vimNavigation)
        restored.vimNavigation = true
        precondition(!restored.homeRowSelection && !restored.typeToFilter)
        restored.typeToFilter = true
        precondition(!restored.homeRowSelection && !restored.vimNavigation)
        print("PASS upstream preference migration preserves fork settings and navigation modes remain exclusive")
    }
}
