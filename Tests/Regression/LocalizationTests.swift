extension L10n {
    @MainActor static func runRegressionTests() {
        let prefs = SwitchPreferences.shared
        let original = prefs.language
        let appearance = prefs.appearance
        defer { prefs.language = original; prefs.appearance = appearance }
        prefs.appearance = .dark
        prefs.language = .simplifiedChinese
        precondition(language == .simplifiedChinese, "Language preference was not persisted")
        precondition(string("Three-finger swipe") == "三指滑动", "Chinese resources missing from the app bundle")
        precondition(string("Swipe horizontally to open the picker, then move in any direction to choose a window. Lift all three fingers to switch.") == "水平滑动打开切换器，再向任意方向移动来选择窗口，抬起三指后完成切换。", "Merged gesture instructions are not translated")
        precondition(string("Build and update instructions") == "构建与更新说明", "Fork update instructions not translated")
        precondition(format("Number of columns in the grid view. %d", 4) == "宫格视图的列数：4", "Chinese formatted string failed")
        precondition(prefs.appearance.label == "深色", "Preference labels did not follow Chinese")
        prefs.language = .english
        precondition(language == .english)
        precondition(string("Three-finger swipe") == "Three-finger swipe", "Switching back to English retained Chinese")
        precondition(prefs.appearance.label == "Dark")
        precondition(string("unknown.regression.key") == "unknown.regression.key", "Missing keys should fall back to their text")
        precondition(AppLanguage.english.locale.identifier == "en")
        precondition(AppLanguage.simplifiedChinese.locale.identifier == "zh-Hans")
        prefs.language = .system
        precondition(language == .system)
        precondition(AppLanguage.allCases.count == 3)
        precondition(BuildInfo.isFork, "Regression bundle must use fork update policy")
        precondition(BuildInfo.forkBuildURL.host == "github.com" && BuildInfo.forkBuildURL.path == "/NicoKam/switch")
        print("PASS bundled Chinese/English localization, live language changes, formatting and fork update policy")
    }
}
