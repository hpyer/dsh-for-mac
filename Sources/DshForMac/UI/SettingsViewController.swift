import AppKit

final class SettingsViewController: NSViewController {
    private let statusValue = NSTextField(labelWithString: "正在读取…")
    private let runtimePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let openVersionsButton = NSButton(title: "打开目录", target: nil, action: nil)
    private let registryPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let updateIntervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let updateChannelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let additionalTagCheckbox = NSButton(checkboxWithTitle: "启用额外标签", target: nil, action: nil)
    private let checkUpdatesButton = NSButton(title: "立即检查", target: nil, action: nil)
    private let checkResultLabel = NSTextField(wrappingLabelWithString: "")
    private let downloadUpdateButton = NSButton(title: "下载", target: nil, action: nil)
    private let portField = NSTextField(string: "")
    private let dshMarketCheckbox = NSButton(checkboxWithTitle: "DSH Market", target: nil, action: nil)
    private let workspaceDrop2AddCheckbox = NSButton(checkboxWithTitle: "拖入文件夹添加工作区", target: nil, action: nil)
    private let pluginStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let applyButton = NSButton(title: "保存", target: nil, action: nil)
    private let settings: AppSettings
    private let onApply: (String?, Bool, [RecommendedDSHPlugin: Bool]) -> Void
    private let onCheckUpdates: () -> Void
    private let onDownloadUpdate: () -> Void
    private let onOpenVersionsDirectory: () -> Void
    private var pendingRecommendedPluginSelections: [RecommendedDSHPlugin: Bool]?

    init(
        settings: AppSettings = .shared,
        onApply: @escaping (String?, Bool, [RecommendedDSHPlugin: Bool]) -> Void,
        onCheckUpdates: @escaping () -> Void,
        onDownloadUpdate: @escaping () -> Void,
        onOpenVersionsDirectory: @escaping () -> Void
    ) {
        self.settings = settings
        self.onApply = onApply
        self.onCheckUpdates = onCheckUpdates
        self.onDownloadUpdate = onDownloadUpdate
        self.onOpenVersionsDirectory = onOpenVersionsDirectory
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let rootView = NSView()
        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        pendingRecommendedPluginSelections = nil
    }

    func update(
        serviceStatus: String,
        runtimeVersion: String?,
        installedVersions: [String],
        updateCheckStatus: String,
        canDownloadUpdate: Bool,
        isUpdateOperationInProgress: Bool,
        recommendedPlugins: [RecommendedDSHPluginState],
        pluginStatus: String,
        isPluginOperationInProgress: Bool
    ) {
        statusValue.stringValue = serviceStatus
        runtimePopup.removeAllItems()
        runtimePopup.addItems(withTitles: installedVersions)
        runtimePopup.isEnabled = !installedVersions.isEmpty
        if let selectedVersion = settings.selectedRuntimeVersion ?? runtimeVersion,
           let index = installedVersions.firstIndex(of: selectedVersion)
        {
            runtimePopup.selectItem(at: index)
        }
        var status = updateCheckStatus
        if status.isEmpty, let version = settings.availableUpdateVersion {
            status = settings.availableUpdateIsDownloaded && installedVersions.contains(version)
                ? "新版本 \(version) 已下载。" : "发现新版本 \(version)，是否下载？"
        }
        checkResultLabel.stringValue = status
        checkResultLabel.toolTip = status
        checkResultLabel.isHidden = status.isEmpty
        checkUpdatesButton.isEnabled = !isUpdateOperationInProgress
        downloadUpdateButton.isHidden = !canDownloadUpdate
        downloadUpdateButton.isEnabled = canDownloadUpdate
        updateRecommendedPlugins(recommendedPlugins, status: pluginStatus, isOperationInProgress: isPluginOperationInProgress)
    }

    func prepareForDisplay() {
        pendingRecommendedPluginSelections = nil
    }

    private func configureView() {
        let appVersionValue = NSTextField(labelWithString: AppMetadata.version)
        appVersionValue.textColor = .secondaryLabelColor
        statusValue.lineBreakMode = .byTruncatingMiddle
        statusValue.textColor = .secondaryLabelColor
        statusValue.maximumNumberOfLines = 1
        runtimePopup.widthAnchor.constraint(equalToConstant: 160).isActive = true
        registryPopup.widthAnchor.constraint(equalToConstant: 160).isActive = true
        updateIntervalPopup.widthAnchor.constraint(equalToConstant: 160).isActive = true
        updateChannelPopup.widthAnchor.constraint(equalToConstant: 100).isActive = true
        portField.stringValue = String(settings.port)
        portField.alignment = .left
        portField.widthAnchor.constraint(equalToConstant: 110).isActive = true

        registryPopup.addItems(withTitles: PackageRegistry.allCases.map(\.displayName))
        registryPopup.selectItem(at: PackageRegistry.allCases.firstIndex(of: settings.registry) ?? 0)
        updateIntervalPopup.addItems(withTitles: DSHUpdateCheckInterval.allCases.map(\.displayName))
        updateIntervalPopup.selectItem(at: DSHUpdateCheckInterval.allCases.firstIndex(of: settings.updateCheckInterval) ?? 0)
        updateChannelPopup.addItems(withTitles: DSHUpdateChannel.allCases.map(\.displayName))
        updateChannelPopup.selectItem(at: DSHUpdateChannel.allCases.firstIndex(of: settings.updateChannel) ?? 0)
        updateChannelPopup.isEnabled = settings.additionalUpdateTagEnabled
        updateChannelPopup.toolTip = "启用后会与 latest 一同检查，用于发现预发布版本。"
        additionalTagCheckbox.state = settings.additionalUpdateTagEnabled ? .on : .off
        additionalTagCheckbox.target = self
        additionalTagCheckbox.action = #selector(additionalTagEnabledChanged)
        dshMarketCheckbox.tag = 0
        workspaceDrop2AddCheckbox.tag = 1
        dshMarketCheckbox.target = self
        workspaceDrop2AddCheckbox.target = self
        dshMarketCheckbox.action = #selector(recommendedPluginChanged(_:))
        workspaceDrop2AddCheckbox.action = #selector(recommendedPluginChanged(_:))
        pluginStatusLabel.textColor = .secondaryLabelColor
        pluginStatusLabel.maximumNumberOfLines = 3
        pluginStatusLabel.isHidden = true

        applyButton.target = self
        applyButton.action = #selector(applyAndRestart)
        applyButton.keyEquivalent = "\r"
        openVersionsButton.target = self
        openVersionsButton.action = #selector(openVersionsDirectory)
        checkUpdatesButton.target = self
        checkUpdatesButton.action = #selector(checkUpdates)
        downloadUpdateButton.target = self
        downloadUpdateButton.action = #selector(downloadUpdate)
        downloadUpdateButton.isBordered = false
        downloadUpdateButton.contentTintColor = .linkColor
        downloadUpdateButton.setContentHuggingPriority(.required, for: .horizontal)
        downloadUpdateButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        downloadUpdateButton.isHidden = true
        checkResultLabel.textColor = .secondaryLabelColor
        checkResultLabel.maximumNumberOfLines = 3
        checkResultLabel.preferredMaxLayoutWidth = 205
        checkResultLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        checkResultLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        checkResultLabel.isHidden = true
        let runtimeControls = NSStackView(views: [runtimePopup, openVersionsButton])
        runtimeControls.orientation = .horizontal
        runtimeControls.spacing = 8
        let updateActionControls = NSStackView(views: [updateIntervalPopup, checkUpdatesButton])
        updateActionControls.orientation = .horizontal
        updateActionControls.spacing = 8
        let downloadControls = NSStackView(views: [checkResultLabel, downloadUpdateButton])
        downloadControls.orientation = .horizontal
        downloadControls.alignment = .firstBaseline
        downloadControls.spacing = 8
        downloadControls.widthAnchor.constraint(equalToConstant: 250).isActive = true
        let updateControls = NSStackView(views: [updateActionControls, downloadControls])
        updateControls.orientation = .vertical
        updateControls.alignment = .leading
        updateControls.spacing = 8
        let additionalTagControls = NSStackView(views: [additionalTagCheckbox, updateChannelPopup])
        additionalTagControls.orientation = .horizontal
        additionalTagControls.alignment = .centerY
        additionalTagControls.spacing = 8

        let content = NSStackView(views: [
            makeRow(label: "DshForMac", value: appVersionValue),
            makeRow(label: "运行状态", value: statusValue),
            makeRow(label: "运行端口", value: portField),
            makeRow(label: "DSH 版本", value: runtimeControls),
            makeRow(label: "DSH 更新", value: updateControls),
            makeRow(label: "预发布更新", value: additionalTagControls),
            makeRow(label: "包下载镜像", value: registryPopup),
            makeDivider(),
            makeRow(label: "推荐插件", value: pluginControls()),
            makeDivider(),
            applyButton,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 15
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 30),
            content.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -26),
            statusValue.widthAnchor.constraint(equalToConstant: 250),
        ])
    }

    private func pluginControls() -> NSStackView {
        let githubButton = NSButton(title: "Github", target: self, action: #selector(openDSHMarketRepository))
        githubButton.isBordered = false
        githubButton.contentTintColor = .linkColor
        githubButton.toolTip = "https://github.com/dsh-market/dsh-market"
        let marketControls = NSStackView(views: [dshMarketCheckbox, githubButton])
        marketControls.orientation = .horizontal
        marketControls.alignment = .centerY
        marketControls.spacing = 8
        let details = NSTextField(wrappingLabelWithString: "勾选状态会在保存后写入 DSH 的 web profile。")
        details.textColor = .secondaryLabelColor
        details.maximumNumberOfLines = 2
        details.preferredMaxLayoutWidth = 250
        let controls = NSStackView(views: [marketControls, workspaceDrop2AddCheckbox, details, pluginStatusLabel])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 6
        return controls
    }

    @objc private func openDSHMarketRepository() {
        guard let url = URL(string: "https://github.com/dsh-market/dsh-market") else { return }
        NSWorkspace.shared.open(url)
    }

    private func updateRecommendedPlugins(
        _ states: [RecommendedDSHPluginState],
        status: String,
        isOperationInProgress: Bool
    ) {
        let actualSelections = Dictionary(uniqueKeysWithValues: states.map { ($0.plugin, $0.isEnabled) })
        if pendingRecommendedPluginSelections == nil {
            pendingRecommendedPluginSelections = actualSelections
        }
        let selections = pendingRecommendedPluginSelections ?? actualSelections
        for state in states {
            let checkbox: NSButton
            switch state.plugin {
            case .dshMarket: checkbox = dshMarketCheckbox
            case .workspaceDrop2Add: checkbox = workspaceDrop2AddCheckbox
            }
            checkbox.state = selections[state.plugin, default: state.isEnabled] ? .on : .off
            checkbox.isEnabled = state.isAvailable && !isOperationInProgress
            if !state.isAvailable {
                checkbox.toolTip = "本地插件资源不可用。"
            } else {
                checkbox.toolTip = state.plugin.detail
            }
        }
        pluginStatusLabel.stringValue = status
        pluginStatusLabel.isHidden = status.isEmpty
    }

    private func makeRow(label: String, value: NSView) -> NSStackView {
        let labelView = NSTextField(labelWithString: label)
        labelView.font = .systemFont(ofSize: 13, weight: .medium)
        labelView.setContentHuggingPriority(.required, for: .horizontal)
        labelView.widthAnchor.constraint(equalToConstant: 92).isActive = true
        let row = NSStackView(views: [labelView, value])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18
        return row
    }

    private func makeDivider() -> NSBox {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 360).isActive = true
        return divider
    }

    @objc private func applyAndRestart() {
        let index = registryPopup.indexOfSelectedItem
        guard PackageRegistry.allCases.indices.contains(index) else { return }
        let registry = PackageRegistry.allCases[index]
        let updateIndex = updateIntervalPopup.indexOfSelectedItem
        guard DSHUpdateCheckInterval.allCases.indices.contains(updateIndex) else { return }
        let updateInterval = DSHUpdateCheckInterval.allCases[updateIndex]
        let channelIndex = updateChannelPopup.indexOfSelectedItem
        guard DSHUpdateChannel.allCases.indices.contains(channelIndex) else { return }
        let updateChannel = DSHUpdateChannel.allCases[channelIndex]
        let additionalTagEnabled = additionalTagCheckbox.state == .on
        guard let port = Int(portField.stringValue), (1...65_535).contains(port) else {
            let alert = NSAlert()
            alert.messageText = "端口无效"
            alert.informativeText = "请输入 1 到 65535 之间的端口号。"
            alert.runModal()
            return
        }
        let version = runtimePopup.titleOfSelectedItem
        let restartRequired = settings.port != port || settings.selectedRuntimeVersion != version
        let pluginSelections = [
            RecommendedDSHPlugin.dshMarket: dshMarketCheckbox.state == .on,
            .workspaceDrop2Add: workspaceDrop2AddCheckbox.state == .on,
        ]
        settings.registry = registry
        settings.selectedRuntimeVersion = version
        settings.port = port
        settings.updateCheckInterval = updateInterval
        settings.updateChannel = updateChannel
        settings.additionalUpdateTagEnabled = additionalTagEnabled
        view.window?.performClose(nil)
        pendingRecommendedPluginSelections = nil
        onApply(version, restartRequired, pluginSelections)
    }

    @objc private func additionalTagEnabledChanged() {
        updateChannelPopup.isEnabled = additionalTagCheckbox.state == .on
    }

    @objc private func openVersionsDirectory() {
        onOpenVersionsDirectory()
    }

    @objc private func checkUpdates() {
        onCheckUpdates()
    }

    @objc private func downloadUpdate() {
        onDownloadUpdate()
    }

    @objc private func recommendedPluginChanged(_ sender: NSButton) {
        guard let plugin = RecommendedDSHPlugin.allCases[safe: sender.tag] else { return }
        var selections = pendingRecommendedPluginSelections ?? [:]
        selections[plugin] = sender.state == .on
        pendingRecommendedPluginSelections = selections
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
