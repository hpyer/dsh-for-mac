import AppKit

final class SettingsViewController: NSViewController {
    private let statusValue = NSTextField(labelWithString: "正在读取…")
    private let runtimePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let openVersionsButton = NSButton(title: "打开目录", target: nil, action: nil)
    private let registryPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let updateIntervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let checkUpdatesButton = NSButton(title: "立即检查", target: nil, action: nil)
    private let checkResultLabel = NSTextField(labelWithString: "")
    private let versionNoticeLabel = NSTextField(wrappingLabelWithString: "")
    private let portField = NSTextField(string: "")
    private let applyButton = NSButton(title: "保存", target: nil, action: nil)
    private let settings: AppSettings
    private let onApply: (PackageRegistry, String?, Int, DSHUpdateCheckInterval, Bool) -> Void
    private let onCheckUpdates: () -> Void
    private let onOpenVersionsDirectory: () -> Void

    init(
        settings: AppSettings = .shared,
        onApply: @escaping (PackageRegistry, String?, Int, DSHUpdateCheckInterval, Bool) -> Void,
        onCheckUpdates: @escaping () -> Void,
        onOpenVersionsDirectory: @escaping () -> Void
    ) {
        self.settings = settings
        self.onApply = onApply
        self.onCheckUpdates = onCheckUpdates
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

    func update(
        serviceStatus: String,
        runtimeVersion: String?,
        installedVersions: [String],
        updateCheckStatus: String
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
        updateCheckStatusChanged(updateCheckStatus)
    }

    func updateCheckStatusChanged(_ status: String) {
        checkResultLabel.stringValue = status
        checkResultLabel.isHidden = status.isEmpty
        checkUpdatesButton.isEnabled = !status.hasPrefix("正在")
        let isVersionNotice = status.hasPrefix("有新版本") || status.hasPrefix("失败：")
        versionNoticeLabel.stringValue = isVersionNotice ? status : ""
        versionNoticeLabel.isHidden = !isVersionNotice
    }

    private func configureView() {
        statusValue.lineBreakMode = .byTruncatingMiddle
        statusValue.textColor = .secondaryLabelColor
        statusValue.maximumNumberOfLines = 1
        runtimePopup.widthAnchor.constraint(equalToConstant: 160).isActive = true
        registryPopup.widthAnchor.constraint(equalToConstant: 160).isActive = true
        updateIntervalPopup.widthAnchor.constraint(equalToConstant: 160).isActive = true
        portField.stringValue = String(settings.port)
        portField.alignment = .left
        portField.widthAnchor.constraint(equalToConstant: 110).isActive = true

        registryPopup.addItems(withTitles: PackageRegistry.allCases.map(\.displayName))
        registryPopup.selectItem(at: PackageRegistry.allCases.firstIndex(of: settings.registry) ?? 0)
        updateIntervalPopup.addItems(withTitles: DSHUpdateCheckInterval.allCases.map(\.displayName))
        updateIntervalPopup.selectItem(at: DSHUpdateCheckInterval.allCases.firstIndex(of: settings.updateCheckInterval) ?? 0)

        applyButton.target = self
        applyButton.action = #selector(applyAndRestart)
        applyButton.keyEquivalent = "\r"
        openVersionsButton.target = self
        openVersionsButton.action = #selector(openVersionsDirectory)
        checkUpdatesButton.target = self
        checkUpdatesButton.action = #selector(checkUpdates)
        checkResultLabel.textColor = .secondaryLabelColor
        checkResultLabel.lineBreakMode = .byTruncatingTail
        checkResultLabel.maximumNumberOfLines = 1
        checkResultLabel.widthAnchor.constraint(equalToConstant: 240).isActive = true
        checkResultLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        checkResultLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        checkResultLabel.isHidden = true
        versionNoticeLabel.textColor = .secondaryLabelColor
        versionNoticeLabel.maximumNumberOfLines = 2
        versionNoticeLabel.isHidden = true

        let runtimeControls = NSStackView(views: [runtimePopup, openVersionsButton])
        runtimeControls.orientation = .horizontal
        runtimeControls.spacing = 8
        let versionControls = NSStackView(views: [runtimeControls, versionNoticeLabel])
        versionControls.orientation = .vertical
        versionControls.alignment = .leading
        versionControls.spacing = 4
        let updateActionControls = NSStackView(views: [updateIntervalPopup, checkUpdatesButton])
        updateActionControls.orientation = .horizontal
        updateActionControls.spacing = 8
        let updateControls = NSStackView(views: [updateActionControls, checkResultLabel])
        updateControls.orientation = .vertical
        updateControls.alignment = .leading
        updateControls.spacing = 8

        let content = NSStackView(views: [
            makeRow(label: "运行状态", value: statusValue),
            makeRow(label: "运行端口", value: portField),
            makeRow(label: "DSH 版本", value: versionControls),
            makeRow(label: "DSH 更新", value: updateControls),
            makeRow(label: "包下载镜像", value: registryPopup),
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
        guard let port = Int(portField.stringValue), (1...65_535).contains(port) else {
            let alert = NSAlert()
            alert.messageText = "端口无效"
            alert.informativeText = "请输入 1 到 65535 之间的端口号。"
            alert.runModal()
            return
        }
        let version = runtimePopup.titleOfSelectedItem
        let restartRequired = settings.port != port || settings.selectedRuntimeVersion != version
        settings.registry = registry
        settings.selectedRuntimeVersion = version
        settings.port = port
        settings.updateCheckInterval = updateInterval
        view.window?.performClose(nil)
        onApply(registry, version, port, updateInterval, restartRequired)
    }

    @objc private func openVersionsDirectory() {
        onOpenVersionsDirectory()
    }

    @objc private func checkUpdates() {
        checkUpdatesButton.isEnabled = false
        checkResultLabel.stringValue = "正在检查更新…"
        checkResultLabel.isHidden = false
        onCheckUpdates()
    }
}
