import AppKit

@main
struct DshForMacMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)

        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate {
    private var windowController: NSWindowController?
    private var settingsWindowController: NSWindowController?
    private weak var mainViewController: MainViewController?
    private let serviceIndicator = NSButton(title: "正在启动", target: nil, action: nil)
    private let updateAvailableIndicator = NSButton(title: "有新版本", target: nil, action: nil)
    private weak var mainToolbar: NSToolbar?
    private var statusItem: NSStatusItem?
    private var serviceStatus = "正在启动 DSH…"
    private var isServiceRunning = false
    private var updateCheckStatus = ""
    private var recommendedPluginStatus = ""
    private var isRecommendedPluginOperationInProgress = false

    private enum ToolbarIdentifier {
        static let updateAvailable = NSToolbarItem.Identifier("updateAvailable")
        static let serviceStatus = NSToolbarItem.Identifier("serviceStatus")
        static let restart = NSToolbarItem.Identifier("restart")
        static let settings = NSToolbarItem.Identifier("settings")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppIcon.image()
        configureMainMenu()
        configureStatusItem()

        let contentViewController = MainViewController()
        contentViewController.onServiceStatusChanged = { [weak self] status, isRunning in
            self?.updateServiceStatus(status, isRunning: isRunning)
        }
        contentViewController.onUpdateCheckStatusChanged = { [weak self] status in
            self?.updateUpdateCheckStatus(status)
        }
        contentViewController.onUpdateAvailableVersionChanged = { [weak self] version in
            self?.updateAvailableUpdateIndicator(version: version)
        }
        contentViewController.onRecommendedPluginOperationStatusChanged = { [weak self] status, isInProgress in
            self?.recommendedPluginStatus = status
            self?.isRecommendedPluginOperationInProgress = isInProgress
            self?.refreshSettings()
        }
        mainViewController = contentViewController
        let initialContentSize = NSSize(width: 1_280, height: 720)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DeepSeek Harness for Mac"
        window.center()
        window.contentViewController = contentViewController
        window.setContentSize(initialContentSize)
        window.contentMinSize = NSSize(width: 390, height: 360)
        window.styleMask.insert(.resizable)
        configureToolbar(for: window)

        windowController = NSWindowController(window: window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainViewController?.checkScheduledUpdates()
        guard !flag, let window = windowController?.window else { return true }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainViewController?.stopUpdateChecks()
        mainViewController?.stopDeepSeekHarness()
    }

    private func configureToolbar(for window: NSWindow) {
        serviceIndicator.isBordered = false
        serviceIndicator.imagePosition = .imageLeading
        serviceIndicator.font = .systemFont(ofSize: 13, weight: .medium)
        serviceIndicator.setContentHuggingPriority(.required, for: .horizontal)
        updateAvailableIndicator.isBordered = false
        updateAvailableIndicator.image = NSImage(
            systemSymbolName: "arrow.down.circle.fill",
            accessibilityDescription: "有新版本"
        )
        updateAvailableIndicator.imagePosition = .imageLeading
        updateAvailableIndicator.contentTintColor = .systemBlue
        updateAvailableIndicator.font = .systemFont(ofSize: 13, weight: .medium)
        updateAvailableIndicator.target = self
        updateAvailableIndicator.action = #selector(showSettings)
        updateAvailableIndicator.setContentHuggingPriority(.required, for: .horizontal)
        updateAvailableUpdateIndicator(version: AppSettings.shared.availableUpdateVersion)

        let toolbar = NSToolbar(identifier: "DshForMacToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        mainToolbar = toolbar
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        updateServiceStatus(serviceStatus, isRunning: isServiceRunning)
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = AppIcon.menuBarImage()
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "DshForMac"

        let menu = NSMenu()
        let restartItem = NSMenuItem(
            title: "一键重启 DSH",
            action: #selector(restartDeepSeekHarness),
            keyEquivalent: "r"
        )
        restartItem.keyEquivalentModifierMask = [.command, .shift]
        restartItem.target = self
        menu.addItem(restartItem)

        let versionItem = NSMenuItem(
            title: "DshForMac \(AppMetadata.version)",
            action: nil,
            keyEquivalent: ""
        )
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 DshForMac", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let applicationMenuItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "DshForMac")
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        applicationMenu.addItem(settingsItem)
        applicationMenu.addItem(.separator())
        let restartItem = NSMenuItem(title: "一键重启 DSH", action: #selector(restartDeepSeekHarness), keyEquivalent: "r")
        restartItem.keyEquivalentModifierMask = [.command, .shift]
        restartItem.target = self
        applicationMenu.addItem(restartItem)
        applicationMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 DshForMac", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        applicationMenu.addItem(quitItem)
        applicationMenuItem.submenu = applicationMenu
        mainMenu.addItem(applicationMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let findMenuItem = NSMenuItem()
        let findMenu = NSMenu(title: "查找")
        findMenu.addItem(textFinderMenuItem(
            title: "查找…",
            action: .showFindInterface,
            keyEquivalent: "f",
            modifierMask: .command
        ))
        findMenu.addItem(textFinderMenuItem(
            title: "查找下一个",
            action: .nextMatch,
            keyEquivalent: "g",
            modifierMask: .command
        ))
        findMenu.addItem(textFinderMenuItem(
            title: "查找上一个",
            action: .previousMatch,
            keyEquivalent: "g",
            modifierMask: [.command, .shift]
        ))
        findMenuItem.submenu = findMenu
        mainMenu.addItem(findMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        let reloadItem = NSMenuItem(title: "重新加载 DSH", action: #selector(reloadDeepSeekHarness), keyEquivalent: "r")
        reloadItem.target = self
        viewMenu.addItem(reloadItem)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func textFinderMenuItem(
        title: String,
        action: NSTextFinder.Action,
        keyEquivalent: String,
        modifierMask: NSEvent.ModifierFlags
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(NSResponder.performTextFinderAction(_:)),
            keyEquivalent: keyEquivalent
        )
        item.keyEquivalentModifierMask = modifierMask
        item.tag = action.rawValue
        return item
    }

    private func updateServiceStatus(_ status: String, isRunning: Bool) {
        serviceStatus = status
        isServiceRunning = isRunning
        serviceIndicator.title = status
        serviceIndicator.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        serviceIndicator.contentTintColor = status.contains("失败") ? .systemRed : (isRunning ? .systemGreen : .systemOrange)
        serviceIndicator.toolTip = status
        statusItem?.button?.toolTip = "DshForMac · \(status)"
        (settingsWindowController?.contentViewController as? SettingsViewController)?.update(
            serviceStatus: status,
            runtimeVersion: mainViewController?.activeDSHVersion,
            installedVersions: mainViewController?.installedDSHVersions() ?? [],
            updateCheckStatus: updateCheckStatus,
            canDownloadUpdate: mainViewController?.canDownloadUpdate ?? false,
            isUpdateOperationInProgress: mainViewController?.isUpdateOperationInProgress ?? false,
            recommendedPlugins: mainViewController?.recommendedPluginStates() ?? [],
            pluginStatus: recommendedPluginStatus,
            isPluginOperationInProgress: isRecommendedPluginOperationInProgress
        )
    }

    private func updateUpdateCheckStatus(_ status: String) {
        updateCheckStatus = status
        let settingsViewController = settingsWindowController?.contentViewController as? SettingsViewController
        settingsViewController?.update(
            serviceStatus: serviceStatus,
            runtimeVersion: mainViewController?.activeDSHVersion,
            installedVersions: mainViewController?.installedDSHVersions() ?? [],
            updateCheckStatus: status,
            canDownloadUpdate: mainViewController?.canDownloadUpdate ?? false,
            isUpdateOperationInProgress: mainViewController?.isUpdateOperationInProgress ?? false,
            recommendedPlugins: mainViewController?.recommendedPluginStates() ?? [],
            pluginStatus: recommendedPluginStatus,
            isPluginOperationInProgress: isRecommendedPluginOperationInProgress
        )
    }

    private func refreshSettings() {
        let settingsViewController = settingsWindowController?.contentViewController as? SettingsViewController
        settingsViewController?.update(
            serviceStatus: serviceStatus,
            runtimeVersion: mainViewController?.activeDSHVersion,
            installedVersions: mainViewController?.installedDSHVersions() ?? [],
            updateCheckStatus: updateCheckStatus,
            canDownloadUpdate: mainViewController?.canDownloadUpdate ?? false,
            isUpdateOperationInProgress: mainViewController?.isUpdateOperationInProgress ?? false,
            recommendedPlugins: mainViewController?.recommendedPluginStates() ?? [],
            pluginStatus: recommendedPluginStatus,
            isPluginOperationInProgress: isRecommendedPluginOperationInProgress
        )
    }

    private func updateAvailableUpdateIndicator(version: String?) {
        updateAvailableIndicator.toolTip = version.map { "发现新版本 \($0)，点击查看设置" }
        guard let mainToolbar else { return }

        if version != nil {
            guard !mainToolbar.items.contains(where: { $0.itemIdentifier == ToolbarIdentifier.updateAvailable }) else {
                return
            }
            let insertionIndex = mainToolbar.items.firstIndex {
                $0.itemIdentifier == ToolbarIdentifier.serviceStatus
            } ?? mainToolbar.items.count
            mainToolbar.insertItem(withItemIdentifier: ToolbarIdentifier.updateAvailable, at: insertionIndex)
        } else if let index = mainToolbar.items.firstIndex(where: {
            $0.itemIdentifier == ToolbarIdentifier.updateAvailable
        }) {
            mainToolbar.removeItem(at: index)
        }
    }

    @objc private func restartDeepSeekHarness() {
        mainViewController?.restartDeepSeekHarness()
    }

    @objc private func reloadDeepSeekHarness() {
        mainViewController?.reloadWebInterface()
    }

    @objc private func showSettings() {
        if settingsWindowController == nil {
            let settingsViewController = SettingsViewController(
                onApply: { [weak self] version, restartRequired, pluginSelections in
                    self?.saveSettings(
                        version: version,
                        restartRequired: restartRequired,
                        pluginSelections: pluginSelections
                    )
                },
                onCheckUpdates: { [weak self] in
                    self?.mainViewController?.checkForUpdatesNow()
                },
                onDownloadUpdate: { [weak self] in
                    self?.mainViewController?.downloadAvailableUpdate()
                },
                onOpenVersionsDirectory: { [weak self] in
                    self?.mainViewController?.openRuntimeVersionsDirectory()
                }
            )
            let settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 510),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            settingsWindow.title = "DshForMac 设置"
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.contentMinSize = NSSize(width: 440, height: 450)
            settingsWindow.contentViewController = settingsViewController
            settingsWindow.center()
            settingsWindowController = NSWindowController(window: settingsWindow)
        }

        let settingsViewController = settingsWindowController?.contentViewController as? SettingsViewController
        settingsViewController?.prepareForDisplay()
        settingsViewController?.update(
            serviceStatus: serviceStatus,
            runtimeVersion: mainViewController?.activeDSHVersion,
            installedVersions: mainViewController?.installedDSHVersions() ?? [],
            updateCheckStatus: updateCheckStatus,
            canDownloadUpdate: mainViewController?.canDownloadUpdate ?? false,
            isUpdateOperationInProgress: mainViewController?.isUpdateOperationInProgress ?? false,
            recommendedPlugins: mainViewController?.recommendedPluginStates() ?? [],
            pluginStatus: recommendedPluginStatus,
            isPluginOperationInProgress: isRecommendedPluginOperationInProgress
        )
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func saveSettings(
        version: String?,
        restartRequired: Bool,
        pluginSelections: [RecommendedDSHPlugin: Bool]
    ) {
        mainViewController?.checkScheduledUpdates()
        let pluginChangesRequired = mainViewController?.hasRecommendedPluginSelectionChanges(pluginSelections) ?? false
        let shouldAskToRestart = restartRequired || pluginChangesRequired
        let shouldRestart = shouldAskToRestart && shouldRestartAfterSaving()

        guard pluginChangesRequired else {
            if shouldRestart {
                mainViewController?.selectDSHVersion(version)
            }
            return
        }

        mainViewController?.applyRecommendedPluginSelections(pluginSelections) { [weak self] didChangePlugins in
            guard let self, shouldRestart, didChangePlugins || restartRequired else { return }
            self.mainViewController?.selectDSHVersion(version)
        }
    }

    private func shouldRestartAfterSaving() -> Bool {
        let alert = NSAlert()
        alert.messageText = "设置已保存"
        alert.informativeText = "运行端口、DSH 版本或推荐插件已变更，是否立即重启 DSH 以应用新设置？"
        alert.addButton(withTitle: "立即重启")
        alert.addButton(withTitle: "稍后")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarIdentifier.updateAvailable:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = updateAvailableIndicator
            item.label = "有新版本"
            item.toolTip = updateAvailableIndicator.toolTip
            return item
        case ToolbarIdentifier.serviceStatus:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = serviceIndicator
            item.label = "运行状态"
            item.toolTip = "运行状态"
            return item
        case ToolbarIdentifier.restart:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "重启"
            item.toolTip = "一键重启 DSH"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "重启")
            item.target = self
            item.action = #selector(restartDeepSeekHarness)
            return item
        case ToolbarIdentifier.settings:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "设置"
            item.toolTip = "设置"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置")
            item.target = self
            item.action = #selector(showSettings)
            return item
        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var identifiers: [NSToolbarItem.Identifier] = [.flexibleSpace]
        if AppSettings.shared.availableUpdateVersion != nil {
            identifiers.append(ToolbarIdentifier.updateAvailable)
        }
        identifiers += [ToolbarIdentifier.serviceStatus, ToolbarIdentifier.restart, ToolbarIdentifier.settings]
        return identifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
}
