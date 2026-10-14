extension StatusBarController {
    func regressionMenuTitles() -> [String] { item.menu?.items.map(\.title) ?? [] }
    func regressionRemoveItem() { NSStatusBar.system.removeStatusItem(item) }
}
