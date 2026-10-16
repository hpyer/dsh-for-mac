import AppKit
import WebKit

final class MainViewController: NSViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    var onServiceStatusChanged: ((String, Bool) -> Void)?
    var onUpdateCheckStatusChanged: ((String) -> Void)?
    var onUpdateAvailableVersionChanged: ((String?) -> Void)?
    var onRecommendedPluginOperationStatusChanged: ((String, Bool) -> Void)?
    var onRequestDSHUpgrade: (() -> Void)?
    var onTaskNotification: ((String, String, String) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "DeepSeek Harness for Mac")
    private let statusLabel = NSTextField(labelWithString: "正在检测 Node.js…")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let primaryButton = NSButton(title: "重新检测", target: nil, action: nil)
    private let upgradeDSHButton = NSButton(title: "检查 DSH 更新…", target: nil, action: nil)
    private let rollbackButton = NSButton(title: "退回上一版本", target: nil, action: nil)
    private let redownloadButton = NSButton(title: "重新下载 DSH", target: nil, action: nil)
    private let chooseNodeButton = NSButton(title: "选择 Node.js 路径", target: nil, action: nil)
    private let nodeWebsiteButton = NSButton(title: "打开 Node.js 官网", target: nil, action: nil)
    private let environmentStack = NSStackView()
    private let webOperationOverlay = NSVisualEffectView()
    private let webOperationLabel = NSTextField(wrappingLabelWithString: "")
    private let webOperationSpinner = NSProgressIndicator()
    private let reconnectButton = NSButton(title: "重新连接", target: nil, action: nil)
    private let marketRestartBridgeToken = UUID().uuidString
    private let sessionRepairBridgeToken = UUID().uuidString
    private var isRepairingSession = false
    private var workspaceDrop2AddBridgeToken: String?
    private var taskNotificationBridgeToken: String?
    private var pendingNotificationSessionId: String?
    private lazy var webView: WorkspaceDrop2AddWebView = {
        let configuration = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(
            WeakScriptMessageHandler(owner: self),
            name: DSHMarketRestartBridge.handlerName
        )
        contentController.add(
            WeakScriptMessageHandler(owner: self),
            name: DSHSessionRepairBridge.handlerName
        )
        contentController.add(
            WeakScriptMessageHandler(owner: self),
            name: Self.workspaceDrop2AddBridgeHandlerName
        )
        contentController.add(
            WeakScriptMessageHandler(owner: self),
            name: Self.taskNotificationBridgeHandlerName
        )
        contentController.addUserScript(
            WKUserScript(
                source: WebKitCompatibility.script,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        contentController.addUserScript(
            WKUserScript(
                source: WebKitCompatibility.modelSelectionMouseScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            )
        )
        contentController.addUserScript(
            WKUserScript(
                source: DSHMarketRestartBridge.script(token: marketRestartBridgeToken),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            )
        )
        configuration.userContentController = contentController
        contentController.addUserScript(WKUserScript(
            source: DSHSessionRepairBridge.script(token: sessionRepairBridgeToken),
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .page
        ))
        contentController.addUserScript(
            WKUserScript(
                source: WebKitCompatibility.conversationLayoutScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        contentController.addUserScript(
            WKUserScript(
                source: WebKitCompatibility.terminalFontScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        let webView = WorkspaceDrop2AddWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.onWorkspaceDirectoryDropped = { [weak self] url in
            self?.deliverWorkspaceDirectory(url)
        }
        return webView
    }()
    private lazy var runtimeManager = DSHRuntimeManager(
        statusHandler: { [weak self] status in
            self?.statusLabel.stringValue = status
            guard let self else { return }
            if self.isLaunchingDeepSeekHarness {
                self.reportStartupStatus(status)
            } else {
                self.reportServiceStatus(status, isRunning: false)
            }
        },
        unexpectedTerminationHandler: { [weak self] statusCode, diagnostic in
            self?.handleUnexpectedTermination(statusCode: statusCode, diagnostic: diagnostic)
        }
    )
    private var didShowMissingNodeAlert = false
    private var isLaunchingDeepSeekHarness = false
    private var didCompleteInitialStartup = false
    private var failedDSHVersion: String?
    private var isCheckingForUpdates = false
    private var isDownloadingUpdate = false
    private var updateCheckTimer: Timer?
    private var didCheckUpdatesAtLaunch = false
    private var lastUpdateCheckAttempt: Date?
    private var webAddress: URL?
    private var webRecoveryTask: Task<Void, Never>?
    private var webRecoveryIdentifier: UUID?
    private var webRecoveryNeeded = false
    private var failedWebLoads = 0
    var isUpdateOperationInProgress: Bool { isCheckingForUpdates || isDownloadingUpdate || isRepairingSession }
    var canDownloadUpdate: Bool {
        guard !isUpdateOperationInProgress, !isLaunchingDeepSeekHarness,
              let version = AppSettings.shared.availableUpdateVersion else { return false }
        return !AppSettings.shared.availableUpdateIsDownloaded || !installedDSHVersions().contains(version)
    }
    private(set) var activeDSHVersion: String?
    private var preferredNodeURL: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: Self.nodePathPreferenceKey) else {
                return nil
            }
            return URL(fileURLWithPath: path)
        }
        set {
            UserDefaults.standard.set(newValue?.path, forKey: Self.nodePathPreferenceKey)
        }
    }

    private static let nodePathPreferenceKey = "preferredNodePath"
    private static let workspaceDrop2AddBridgeHandlerName = "dshWorkspaceDrop2AddBridge"
    private static let taskNotificationBridgeHandlerName = "dshTaskNotificationBridge"

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkScheduledUpdates() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        updateCheckTimer = timer
        NotificationCenter.default.addObserver(
            self, selector: #selector(checkScheduledUpdates), name: NSApplication.didBecomeActiveNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleSystemWake), name: NSWorkspace.didWakeNotification, object: nil
        )
        refreshRuntimeStatus()
    }

    private func configureView() {
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        statusLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 4

        primaryButton.target = self
        primaryButton.action = #selector(primaryButtonPressed)
        upgradeDSHButton.target = self
        upgradeDSHButton.action = #selector(requestDSHUpgrade)
        upgradeDSHButton.isHidden = true
        rollbackButton.target = self
        rollbackButton.action = #selector(rollbackDeepSeekHarness)
        rollbackButton.isHidden = true
        redownloadButton.target = self
        redownloadButton.action = #selector(redownloadDeepSeekHarness)
        chooseNodeButton.target = self
        chooseNodeButton.action = #selector(chooseNode)
        nodeWebsiteButton.target = self
        nodeWebsiteButton.action = #selector(openNodeWebsite)

        environmentStack.addArrangedSubview(titleLabel)
        environmentStack.addArrangedSubview(statusLabel)
        environmentStack.addArrangedSubview(detailLabel)
        environmentStack.addArrangedSubview(primaryButton)
        environmentStack.addArrangedSubview(upgradeDSHButton)
        environmentStack.addArrangedSubview(rollbackButton)
        environmentStack.addArrangedSubview(redownloadButton)
        environmentStack.addArrangedSubview(chooseNodeButton)
        environmentStack.addArrangedSubview(nodeWebsiteButton)
        environmentStack.orientation = .vertical
        environmentStack.alignment = .leading
        environmentStack.spacing = 12
        environmentStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(environmentStack)

        NSLayoutConstraint.activate([
            environmentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 48),
            environmentStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -48),
            environmentStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    @objc private func primaryButtonPressed() {
        let status = NodeRuntimeDetector().detect(preferredNodeURL: preferredNodeURL)
        guard case let .ready(runtime) = status else {
            refreshRuntimeStatus()
            return
        }
        if failedDSHVersion != nil {
            restartDeepSeekHarness(using: runtime)
        } else {
            startDeepSeekHarness(using: runtime)
        }
    }

    private func startDeepSeekHarness(using runtime: NodeRuntime) {
        guard !isLaunchingDeepSeekHarness else { return }
        isLaunchingDeepSeekHarness = true
        rollbackButton.isHidden = true
        primaryButton.isEnabled = false
        redownloadButton.isEnabled = false
        chooseNodeButton.isEnabled = false
        nodeWebsiteButton.isEnabled = false
        statusLabel.stringValue = "正在准备 DSH…"
        detailLabel.stringValue = "首次启动需要下载并校验运行时，请保持窗口打开。"
        reportStartupStatus("正在准备 DSH…")

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.runtimeManager.start(using: runtime)
                self.isLaunchingDeepSeekHarness = false
                self.activeDSHVersion = result.version
                self.refreshAvailableUpdateVersion()
                self.failedDSHVersion = nil
                self.showWebInterface(at: result.address)
                self.reportServiceStatus("运行中 · \(result.version)", isRunning: true)
                self.scheduleUpdateCheckIfNeeded(using: runtime)
            } catch {
                self.isLaunchingDeepSeekHarness = false
                self.failedDSHVersion = self.runtimeManager.lastAttemptedVersion ?? self.runtimeManager.preferredRuntimeVersion()
                self.showStartupError(error)
            }
        }
    }

    private func restartDeepSeekHarness(using runtime: NodeRuntime, preferredVersion: String? = nil) {
        guard !isLaunchingDeepSeekHarness, !isRepairingSession else { return }
        isLaunchingDeepSeekHarness = true
        rollbackButton.isHidden = true
        let version = runtimeManager.runtimeVersionForRestart(preferredVersion: preferredVersion)
        let startupStatus = version.map { "\($0)" } ?? "正在启动 DSH…"
        showStartupProgress(
            status: startupStatus,
            detail: "正在重新启动本地服务，请保持窗口打开。"
        )
        primaryButton.isEnabled = false
        redownloadButton.isEnabled = false
        reportStartupStatus("正在重启 DSH…")

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.runtimeManager.restart(using: runtime, preferredVersion: version)
                self.isLaunchingDeepSeekHarness = false
                self.activeDSHVersion = result.version
                self.refreshAvailableUpdateVersion()
                self.failedDSHVersion = nil
                self.showWebInterface(at: result.address)
                self.reportServiceStatus("运行中 · \(result.version)", isRunning: true)
                self.scheduleUpdateCheckIfNeeded(using: runtime)
            } catch {
                self.isLaunchingDeepSeekHarness = false
                self.failedDSHVersion = self.runtimeManager.lastAttemptedVersion ?? self.runtimeManager.preferredRuntimeVersion()
                self.showStartupError(error)
            }
        }
    }

    private func showWebInterface(at address: URL) {
        cancelWebRecovery()
        webAddress = address
        webRecoveryNeeded = false
        failedWebLoads = 0
        hideWebOperationStatus()
        environmentStack.isHidden = true
        if webView.superview == nil {
            webView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(webView)
            configureWebOperationOverlay()

            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                webView.topAnchor.constraint(equalTo: view.topAnchor),
                webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }
        webView.isHidden = false
        WebKitDraftCompatibility.configure(webView.configuration.userContentController, for: activeDSHVersion)
        webView.load(URLRequest(url: address))
    }

    private func showStartupError(_ error: Error) {
        let requiresUpgrade = (error as? DSHRuntimeError)?.requiresUpgrade == true
        cancelWebRecovery()
        webAddress = nil
        activeDSHVersion = nil
        refreshRollbackButton()
        hideWebOperationStatus()
        showEnvironmentView()
        primaryButton.isEnabled = true
        redownloadButton.isEnabled = true
        chooseNodeButton.isHidden = true
        nodeWebsiteButton.isHidden = true
        statusLabel.stringValue = requiresUpgrade ? "DSH 版本过低" : "DSH 启动失败"
        detailLabel.stringValue = error.localizedDescription
        primaryButton.title = "重新启动 DSH"
        primaryButton.isHidden = requiresUpgrade
        redownloadButton.isHidden = requiresUpgrade
        upgradeDSHButton.isHidden = !requiresUpgrade
        reportServiceStatus(requiresUpgrade ? "DSH 版本过低" : "DSH 启动失败", isRunning: false)
    }

    private func refreshRollbackButton() {
        let version = runtimeManager.rollbackRuntimeVersion(excluding: failedDSHVersion)
        rollbackButton.isHidden = version == nil
        rollbackButton.title = version.map { "退回上一版本（\($0)）" } ?? "退回上一版本"
    }

    @objc private func rollbackDeepSeekHarness() {
        guard !isLaunchingDeepSeekHarness, !isUpdateOperationInProgress,
              let version = runtimeManager.rollbackRuntimeVersion(excluding: failedDSHVersion) else { return }
        // An explicit rollback changes both the requested and displayed version.
        selectDSHVersion(version)
    }

    private func handleUnexpectedTermination(statusCode: Int32, diagnostic: String?) {
        guard !isLaunchingDeepSeekHarness else { return }
        cancelWebRecovery()
        webAddress = nil
        failedDSHVersion = activeDSHVersion ?? runtimeManager.lastAttemptedVersion
        activeDSHVersion = nil
        refreshRollbackButton()
        showEnvironmentView()
        primaryButton.isEnabled = true
        redownloadButton.isEnabled = true
        chooseNodeButton.isHidden = true
        nodeWebsiteButton.isHidden = true
        statusLabel.stringValue = "DSH 已退出（状态码 \(statusCode)）"
        detailLabel.stringValue = diagnostic ?? "DSH 在运行中意外退出。请尝试重新启动或切换到其他已安装版本。"
        primaryButton.title = "重新启动 DSH"
        primaryButton.isHidden = false
        redownloadButton.isHidden = false
        upgradeDSHButton.isHidden = true
        reportServiceStatus("DSH 已退出（状态码 \(statusCode)）。", isRunning: false)
    }

    func stopDeepSeekHarness() {
        cancelWebRecovery()
        webAddress = nil
        runtimeManager.stop()
        hideWebOperationStatus()
        activeDSHVersion = nil
        reportServiceStatus("DSH 已停止", isRunning: false)
    }

    func stopUpdateChecks() {
        cancelWebRecovery()
        updateCheckTimer?.invalidate()
        updateCheckTimer = nil
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.didWakeNotification, object: nil)
    }

    func restartDeepSeekHarness() {
        guard !isLaunchingDeepSeekHarness else { return }
        let status = NodeRuntimeDetector().detect(preferredNodeURL: preferredNodeURL)
        guard case let .ready(runtime) = status else {
            refreshRuntimeStatus()
            return
        }
        restartDeepSeekHarness(using: runtime)
    }

    func reloadWebInterface() {
        guard webView.superview != nil else { return }
        webView.reload()
    }

    func selectDSHVersion(_ version: String?) {
        guard !isRepairingSession else { return }
        AppSettings.shared.selectedRuntimeVersion = version
        guard !isLaunchingDeepSeekHarness else { return }
        let status = NodeRuntimeDetector().detect(preferredNodeURL: preferredNodeURL)
        guard case let .ready(runtime) = status else {
            refreshRuntimeStatus()
            return
        }
        restartDeepSeekHarness(using: runtime, preferredVersion: version)
    }

    func installedDSHVersions() -> [String] {
        runtimeManager.installedVersions()
    }

    func recommendedPluginStates() -> [RecommendedDSHPluginState] {
        runtimeManager.recommendedPluginStates()
    }

    func hasRecommendedPluginSelectionChanges(_ selections: [RecommendedDSHPlugin: Bool]) -> Bool {
        let currentSelections = Dictionary(uniqueKeysWithValues: recommendedPluginStates().map { ($0.plugin, $0.isEnabled) })
        return RecommendedDSHPlugin.allCases.contains { plugin in
            guard let enabled = selections[plugin] else { return false }
            return currentSelections[plugin] != enabled
        }
    }

    func applyRecommendedPluginSelections(
        _ selections: [RecommendedDSHPlugin: Bool],
        dshVersion requestedVersion: String?,
        completion: @escaping (Bool) -> Void
    ) {
        guard !isLaunchingDeepSeekHarness else {
            onRecommendedPluginOperationStatusChanged?("DSH 正在启动，请稍后再调整插件。", false)
            completion(false)
            return
        }
        guard case let .ready(runtime) = NodeRuntimeDetector().detect(preferredNodeURL: preferredNodeURL) else {
            onRecommendedPluginOperationStatusChanged?("Node.js 尚未就绪，无法调整插件。", false)
            completion(false)
            return
        }
        guard let version = requestedVersion ?? activeDSHVersion ?? runtimeManager.preferredRuntimeVersion() else {
            onRecommendedPluginOperationStatusChanged?("尚未安装可用的 DSH 版本。", false)
            completion(false)
            return
        }

        let currentSelections = Dictionary(uniqueKeysWithValues: recommendedPluginStates().map { ($0.plugin, $0.isEnabled) })
        let changes = RecommendedDSHPlugin.allCases.compactMap { plugin -> (RecommendedDSHPlugin, Bool)? in
            guard let enabled = selections[plugin], currentSelections[plugin] != enabled else { return nil }
            return (plugin, enabled)
        }
        guard !changes.isEmpty else {
            completion(false)
            return
        }

        showStartupProgress(
            status: "正在保存推荐插件设置…",
            detail: "正在写入 DSH profile，请保持窗口打开。"
        )
        onRecommendedPluginOperationStatusChanged?("正在应用推荐插件变更…", true)
        Task { [weak self] in
            guard let self else { return }
            var didChangePlugins = false
            do {
                for (plugin, enabled) in changes {
                    _ = try await self.runtimeManager.setRecommendedPlugin(
                        plugin,
                        enabled: enabled,
                        using: runtime,
                        dshVersion: version
                    )
                    didChangePlugins = true
                }
                self.onRecommendedPluginOperationStatusChanged?("", false)
                completion(didChangePlugins)
                if !self.isLaunchingDeepSeekHarness {
                    self.restoreWebInterfaceAfterTransientOperation()
                }
            } catch {
                self.onRecommendedPluginOperationStatusChanged?("推荐插件保存失败：\(error.localizedDescription)", false)
                completion(didChangePlugins)
                if !self.isLaunchingDeepSeekHarness {
                    self.restoreWebInterfaceAfterTransientOperation()
                }
            }
        }
    }

    func openRuntimeVersionsDirectory() {
        guard let directory = runtimeManager.runtimeVersionsDirectoryURL() else { return }
        NSWorkspace.shared.open(directory)
    }

    func checkForUpdatesNow() {
        guard !isUpdateOperationInProgress, !isLaunchingDeepSeekHarness else { return }
        guard case let .ready(runtime) = NodeRuntimeDetector().detect(preferredNodeURL: preferredNodeURL) else {
            onUpdateCheckStatusChanged?("失败：Node.js 尚未就绪，无法检查 DSH 更新。")
            return
        }
        performUpdateCheck(using: runtime)
    }

    @objc private func refreshRuntimeStatus() {
        rollbackButton.isHidden = true
        let status = NodeRuntimeDetector().detect(preferredNodeURL: preferredNodeURL)
        statusLabel.stringValue = status.title
        detailLabel.stringValue = status.detail

        if case let .ready(runtime) = status {
            primaryButton.isHidden = true
            upgradeDSHButton.isHidden = true
            redownloadButton.isHidden = true
            chooseNodeButton.isHidden = true
            nodeWebsiteButton.isHidden = true
            if !didCompleteInitialStartup {
                didCompleteInitialStartup = true
                startDeepSeekHarness(using: runtime)
            }
        } else {
            primaryButton.isHidden = false
            upgradeDSHButton.isHidden = true
            primaryButton.title = "重新检测"
            redownloadButton.isHidden = true
            chooseNodeButton.isHidden = false
            nodeWebsiteButton.isHidden = false
        }

        if !status.isReady {
            reportServiceStatus(status.title, isRunning: false)
        }

        if case .notFound = status, !didShowMissingNodeAlert {
            didShowMissingNodeAlert = true
            presentMissingNodeAlert()
        }
    }

    @objc private func chooseNode() {
        let panel = NSOpenPanel()
        panel.title = "选择 Node.js 可执行文件"
        panel.message = "请选择 Node.js 的 node 可执行文件。"
        panel.prompt = "选择 Node"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = preferredNodeURL?.deletingLastPathComponent()

        guard panel.runModal() == .OK, let nodeURL = panel.url else {
            return
        }

        preferredNodeURL = nodeURL
        didShowMissingNodeAlert = true
        refreshRuntimeStatus()
    }

    @objc private func openNodeWebsite() {
        NSWorkspace.shared.open(URL(string: "https://nodejs.org/")!)
    }

    private func presentMissingNodeAlert() {
        let alert = NSAlert()
        alert.messageText = "需要安装 Node.js"
        alert.informativeText = "DshForMac 不捆绑 Node.js。请安装兼容的 Node.js（当前建议 Node 22.19+ 或 24+），安装完成后回到应用重新检测。"
        alert.addButton(withTitle: "打开 Node.js 官网")
        alert.addButton(withTitle: "稍后处理")
        if alert.runModal() == .alertFirstButtonReturn {
            openNodeWebsite()
        }
    }

    private func showEnvironmentView() {
        hideWebOperationStatus()
        resetWorkspaceDrop2AddBridge()
        taskNotificationBridgeToken = nil
        webView.stopLoading()
        webView.isHidden = true
        environmentStack.isHidden = false
    }

    /// Uses the same presentation for an initial launch and a subsequent
    /// restart, rather than leaving a dimmed WebView visible underneath.
    private func showStartupProgress(status: String, detail: String) {
        rollbackButton.isHidden = true
        upgradeDSHButton.isHidden = true
        showEnvironmentView()
        statusLabel.stringValue = status
        detailLabel.stringValue = detail
        primaryButton.isHidden = true
        redownloadButton.isHidden = true
        chooseNodeButton.isHidden = true
        nodeWebsiteButton.isHidden = true
    }

    private func restoreWebInterfaceAfterTransientOperation() {
        guard webView.superview != nil else { return }
        environmentStack.isHidden = true
        webView.isHidden = false
    }

    private func configureWebOperationOverlay() {
        guard webOperationOverlay.superview == nil else { return }
        webOperationOverlay.material = .underWindowBackground
        webOperationOverlay.blendingMode = .withinWindow
        webOperationOverlay.state = .active
        webOperationOverlay.isHidden = true
        webOperationOverlay.translatesAutoresizingMaskIntoConstraints = false
        webOperationSpinner.style = .spinning
        webOperationSpinner.controlSize = .regular
        webOperationSpinner.startAnimation(nil)
        webOperationLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        webOperationLabel.textColor = .secondaryLabelColor
        webOperationLabel.alignment = .center
        webOperationLabel.preferredMaxLayoutWidth = 320
        reconnectButton.target = self
        reconnectButton.action = #selector(retryWebConnection)
        reconnectButton.isHidden = true
        let content = NSStackView(views: [webOperationSpinner, webOperationLabel, reconnectButton])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        webOperationOverlay.addSubview(content)
        view.addSubview(webOperationOverlay)
        NSLayoutConstraint.activate([
            webOperationOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webOperationOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webOperationOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            webOperationOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.centerXAnchor.constraint(equalTo: webOperationOverlay.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: webOperationOverlay.centerYAnchor),
        ])
    }

    private func showWebOperationStatus(_ status: String) {
        configureWebOperationOverlay()
        webOperationLabel.stringValue = status
        webOperationSpinner.isHidden = false
        webOperationSpinner.startAnimation(nil)
        reconnectButton.isHidden = true
        webOperationOverlay.isHidden = false
    }

    private func hideWebOperationStatus() {
        webOperationOverlay.isHidden = true
        reconnectButton.isHidden = true
        webOperationSpinner.stopAnimation(nil)
    }

    @objc private func redownloadDeepSeekHarness() {
        let status = NodeRuntimeDetector().detect(preferredNodeURL: preferredNodeURL)
        guard case let .ready(runtime) = status else {
            refreshRuntimeStatus()
            return
        }

        do {
            if let failedDSHVersion {
                try runtimeManager.removeRuntimeVersion(failedDSHVersion)
                self.failedDSHVersion = nil
            }
        } catch {
            showStartupError(error)
            return
        }

        isLaunchingDeepSeekHarness = true
        rollbackButton.isHidden = true
        primaryButton.isEnabled = false
        redownloadButton.isEnabled = false
        statusLabel.stringValue = "正在重新下载 DSH…"
        detailLabel.stringValue = "将删除失败版本后下载并校验最新 DSH。"
        reportStartupStatus("正在重新下载 DSH…")
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.runtimeManager.downloadLatestAndStart(using: runtime)
                self.isLaunchingDeepSeekHarness = false
                self.activeDSHVersion = result.version
                self.refreshAvailableUpdateVersion()
                self.failedDSHVersion = nil
                self.showWebInterface(at: result.address)
                self.reportServiceStatus("运行中 · \(result.version)", isRunning: true)
                self.scheduleUpdateCheckIfNeeded(using: runtime)
            } catch {
                self.isLaunchingDeepSeekHarness = false
                self.failedDSHVersion = self.runtimeManager.lastAttemptedVersion ?? self.runtimeManager.preferredRuntimeVersion()
                self.showStartupError(error)
            }
        }
    }

    @objc private func requestDSHUpgrade() {
        onRequestDSHUpgrade?()
    }

    private func scheduleUpdateCheckIfNeeded(using runtime: NodeRuntime) {
        guard !didCheckUpdatesAtLaunch else { return }
        didCheckUpdatesAtLaunch = true
        guard AppSettings.shared.shouldCheckForUpdates(), !isUpdateOperationInProgress else { return }
        performUpdateCheck(using: runtime)
    }

    @objc func checkScheduledUpdates() {
        guard activeDSHVersion != nil, !isLaunchingDeepSeekHarness, !isUpdateOperationInProgress,
              AppSettings.shared.shouldCheckForUpdates(
                isApplicationLaunch: false, lastAttemptDate: lastUpdateCheckAttempt
              ) else { return }
        lastUpdateCheckAttempt = Date()
        guard case let .ready(runtime) = NodeRuntimeDetector().detect(preferredNodeURL: preferredNodeURL) else { return }
        performUpdateCheck(using: runtime)
    }

    @objc private func handleSystemWake() {
        checkScheduledUpdates()
        startWebRecovery()
    }

    private func cancelWebRecovery() {
        webRecoveryTask?.cancel()
        webRecoveryTask = nil
        webRecoveryIdentifier = nil
    }

    private func startWebRecovery() {
        guard activeDSHVersion != nil, !isLaunchingDeepSeekHarness,
              webView.superview != nil, let address = webAddress else { return }
        cancelWebRecovery()
        let identifier = UUID()
        webRecoveryIdentifier = identifier
        webRecoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.webRecoveryIdentifier == identifier {
                    self.webRecoveryTask = nil
                    self.webRecoveryIdentifier = nil
                }
            }
            for attempt in 0..<4 {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                }
                guard !Task.isCancelled, self.activeDSHVersion != nil,
                      self.webAddress == address else { return }
                if await self.isWebServiceReachable(at: address) {
                    guard !Task.isCancelled, self.activeDSHVersion != nil,
                          self.webAddress == address else { return }
                    if self.webRecoveryNeeded {
                        self.showWebOperationStatus("正在重新连接 DSH…")
                        if let pageURL = self.webView.url, self.isLocalDSHURL(pageURL) {
                            self.webView.reload()
                        } else {
                            self.webView.load(URLRequest(url: address))
                        }
                    }
                    return
                }
                guard !Task.isCancelled, self.activeDSHVersion != nil,
                      self.webAddress == address else { return }
                self.webRecoveryNeeded = true
                self.showWebOperationStatus("DSH 连接中断，正在重试…")
                self.reportServiceStatus("DSH 连接中断，正在重试…", isRunning: false)
            }
            guard !Task.isCancelled, self.activeDSHVersion != nil,
                  self.webAddress == address else { return }
            self.showWebConnectionFailure()
        }
    }

    private func isWebServiceReachable(at address: URL) async -> Bool {
        var request = URLRequest(url: address)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 3
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let response = response as? HTTPURLResponse,
              let responseURL = response.url, isLocalDSHURL(responseURL) else { return false }
        return (200..<400).contains(response.statusCode)
    }

    private func showWebConnectionFailure() {
        showWebOperationStatus("无法连接 DSH。可重新连接，或使用工具栏重启 DSH。")
        webOperationSpinner.stopAnimation(nil)
        webOperationSpinner.isHidden = true
        reconnectButton.isHidden = false
        reportServiceStatus("DSH 连接中断", isRunning: false)
    }

    @objc private func retryWebConnection() {
        failedWebLoads = 0
        webRecoveryNeeded = true
        startWebRecovery()
    }

    private func performUpdateCheck(using runtime: NodeRuntime) {
        guard !isUpdateOperationInProgress else { return }
        let registry = AppSettings.shared.registry
        let updateTags = AppSettings.shared.updateTags
        isCheckingForUpdates = true
        lastUpdateCheckAttempt = Date()
        onUpdateCheckStatusChanged?("正在检查 DSH 更新…")
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.runtimeManager.checkForUpdates(
                    using: runtime,
                    reportsProgress: false,
                    updateStatusHandler: { [weak self] status in
                        self?.onUpdateCheckStatusChanged?(status)
                    }
                )
                guard registry == AppSettings.shared.registry, updateTags == AppSettings.shared.updateTags else {
                    self.isCheckingForUpdates = false
                    self.lastUpdateCheckAttempt = nil
                    self.onUpdateCheckStatusChanged?("更新来源已变更，请重新检查。")
                    return
                }
                AppSettings.shared.lastUpdateCheckDate = Date()
                self.recordAvailableUpdateVersion(result.version)
                AppSettings.shared.availableUpdateIsDownloaded = result.isInstalled
                let unavailableSuffix = result.unavailableTags.isEmpty
                    ? ""
                    : "（未能检查 \(result.unavailableTags.joined(separator: "、"))）"
                let message: String
                if AppSettings.shared.availableUpdateVersion == nil {
                    message = "DSH 已是最新版本。\(unavailableSuffix)"
                } else if result.isInstalled {
                    message = "DSH 新版本 \(result.version) 已下载。\(unavailableSuffix)"
                } else {
                    message = "发现 DSH 新版本 \(result.version)，是否下载？\(unavailableSuffix)"
                }
                self.isCheckingForUpdates = false
                self.onUpdateCheckStatusChanged?(message)
            } catch {
                self.isCheckingForUpdates = false
                self.onUpdateCheckStatusChanged?("失败：\(error.localizedDescription)")
            }
        }
    }

    func downloadAvailableUpdate() {
        guard canDownloadUpdate, let version = AppSettings.shared.availableUpdateVersion else { return }
        guard case let .ready(runtime) = NodeRuntimeDetector().detect(preferredNodeURL: preferredNodeURL) else {
            onUpdateCheckStatusChanged?("失败：Node.js 尚未就绪，无法下载 DSH 更新。")
            return
        }
        isDownloadingUpdate = true
        onUpdateCheckStatusChanged?("正在下载 DSH \(version)…")
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runtimeManager.downloadVersion(version, using: runtime)
                if AppSettings.shared.availableUpdateVersion == version {
                    AppSettings.shared.availableUpdateIsDownloaded = true
                }
                self.isDownloadingUpdate = false
                self.onUpdateCheckStatusChanged?("DSH 新版本 \(version) 已下载，可在 DSH 版本中选择。")
            } catch {
                AppSettings.shared.availableUpdateIsDownloaded = false
                self.isDownloadingUpdate = false
                self.onUpdateCheckStatusChanged?("下载 \(version) 失败：\(error.localizedDescription) 请重试下载。")
            }
        }
    }

    private func recordAvailableUpdateVersion(_ version: String) {
        let availableVersion: String?
        if let activeDSHVersion,
           let activeVersion = SemanticVersion(string: activeDSHVersion),
           let candidateVersion = SemanticVersion(string: version)
        {
            availableVersion = activeVersion < candidateVersion ? version : nil
        } else {
            availableVersion = version == activeDSHVersion ? nil : version
        }
        AppSettings.shared.availableUpdateVersion = availableVersion
        onUpdateAvailableVersionChanged?(availableVersion)
    }

    private func refreshAvailableUpdateVersion() {
        guard let availableVersion = AppSettings.shared.availableUpdateVersion else {
            onUpdateAvailableVersionChanged?(nil)
            return
        }
        recordAvailableUpdateVersion(availableVersion)
        if AppSettings.shared.availableUpdateVersion == nil {
            onUpdateCheckStatusChanged?("DSH 已是最新版本。")
        }
    }

    private func reportServiceStatus(_ status: String, isRunning: Bool) {
        onServiceStatusChanged?(status, isRunning)
    }

    private func reportStartupStatus(_ status: String) {
        reportServiceStatus("启动中 · \(status)", isRunning: false)
    }

    private func isLocalDSHURL(_ url: URL) -> Bool {
        url.scheme == "http"
            && url.host == "127.0.0.1"
            && url.port == AppSettings.shared.port
    }

    /// Installs in the page's JavaScript world after the plugin handshake. It
    /// runs on window capture before DSH's document-level attachment listener.
    private func installWorkspaceDrop2AddPageProtection() {
        let script = """
        (() => {
          if (window.__dshForMacWorkspaceDrop2AddNativeGuard?.installed) return;
          const guard = window.__dshForMacWorkspaceDrop2AddNativeGuard = {
            installed: true,
            enabled: true,
            layoutKnown: false,
            sidebarWidth: 0
          };
          const scopeStyleID = 'dsh-workspace-drop2add-attachment-scope';
          const updateAttachmentScope = (width) => {
            let style = document.getElementById(scopeStyleID);
            if (!style) {
              style = document.createElement('style');
              style.id = scopeStyleID;
              document.head.appendChild(style);
            }
            const sidebarWidth = Math.max(0, Math.round(width));
            style.textContent = `
              :root { --dsh-workspace-drop2add-sidebar-width: ${sidebarWidth}px; }
              div[role="status"][class$="_mask"] {
                left: var(--dsh-workspace-drop2add-sidebar-width) !important;
              }
            `;
          };
          guard.updateAttachmentScope = updateAttachmentScope;
          // The plugin reports its measured width immediately after this ready
          // handshake. Scope the overlay conservatively until then.
          updateAttachmentScope(Math.min(438, window.innerWidth * 0.4));
          const shouldProtect = (event) => {
            if (!guard.enabled || !Array.from(event.dataTransfer?.types ?? []).includes('Files')) return false;
            const width = guard.layoutKnown ? guard.sidebarWidth : Math.min(438, window.innerWidth * 0.4);
            return width >= 120
              && event.clientX >= 0
              && event.clientX <= width
              && event.clientY <= window.innerHeight - 72;
          };
          for (const name of ['dragenter', 'dragover', 'dragleave', 'drop']) {
            window.addEventListener(name, (event) => {
              if (!shouldProtect(event)) return;
              try { window.__dshForMacWorkspaceDrop2AddProtection?.onDragEvent?.(name); } catch (_) {}
              if (name === 'dragover') event.dataTransfer.dropEffect = 'copy';
              event.preventDefault();
              event.stopImmediatePropagation();
            }, true);
          }
        })();
        """
        webView.evaluateJavaScript(script)
    }

    private func updateWorkspaceDrop2AddPageProtection(width: CGFloat, enabled: Bool = true) {
        let script = """
        (() => {
          const guard = window.__dshForMacWorkspaceDrop2AddNativeGuard;
          if (!guard) return;
          guard.enabled = \(enabled ? "true" : "false");
          guard.layoutKnown = true;
          guard.sidebarWidth = \(width);
          guard.updateAttachmentScope?.(guard.sidebarWidth);
        })();
        """
        webView.evaluateJavaScript(script)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let payload = message.body as? [String: Any]
        else {
            return
        }

        if message.name == Self.workspaceDrop2AddBridgeHandlerName {
            registerWorkspaceDrop2AddBridge(payload)
            return
        }

        if message.name == Self.taskNotificationBridgeHandlerName {
            guard let url = message.frameInfo.request.url, isLocalDSHURL(url) else { return }
            receiveTaskNotificationBridge(payload)
            return
        }

        if message.name == DSHSessionRepairBridge.handlerName {
            guard let url = message.frameInfo.request.url, isLocalDSHURL(url),
                  payload["token"] as? String == sessionRepairBridgeToken,
                  let request = DSHSessionRepairRequest(payload: payload) else { return }
            repairSession(request)
            return
        }

        guard message.name == DSHMarketRestartBridge.handlerName,
              let url = message.frameInfo.request.url, isLocalDSHURL(url),
              payload["token"] as? String == marketRestartBridgeToken
        else { return }

        restartDeepSeekHarness()
    }

    private func repairSession(_ request: DSHSessionRepairRequest) {
        guard !isLaunchingDeepSeekHarness, !isUpdateOperationInProgress,
              let version = activeDSHVersion,
              case let .ready(runtime) = NodeRuntimeDetector().detect(preferredNodeURL: preferredNodeURL)
        else { return }
        isRepairingSession = true
        cancelWebRecovery()
        showWebOperationStatus("正在检查会话兼容性…")
        Task { [weak self] in
            guard let self else { return }
            var serviceStopped = false
            do {
                let plan = try await self.runtimeManager.operateOnSession(
                    action: "analyze", request: request, version: version, using: runtime
                )
                self.hideWebOperationStatus()
                guard let digest = plan.digest, let changed = plan.changed else {
                    throw DSHSessionRepairError(code: "operationFailed")
                }
                let alert = NSAlert()
                alert.messageText = "按 DSH \(version) 兼容修复？"
                alert.informativeText = "将先备份并校验原始压缩日志，再生成临时修复文件，由当前版本读取器校验通过后替换。\n\n本次会将 \(changed) 条新版后台任务记录标记为旧版可忽略，保留消息、事件内容和序号。旧版无法恢复这些新版任务的状态。操作会重启 DSH，请先结束其他会话中的运行任务。\n\n可从“文件 → 恢复会话备份…”撤销；修复后新增历史时将拒绝覆盖。"
                alert.addButton(withTitle: "备份并修复")
                alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else {
                    self.isRepairingSession = false
                    return
                }
                self.showWebOperationStatus("正在备份、校验并修复会话…")
                serviceStopped = true
                let result = try await self.runtimeManager.operateOnSession(
                    action: "repair", request: request, digest: digest, version: version, using: runtime
                )
                self.hideWebOperationStatus()
                let completed = NSAlert()
                completed.messageText = "会话兼容修复已完成"
                completed.informativeText = "已通过 DSH \(version) 的严格读取校验。原始日志备份已保留，可通过“文件 → 恢复会话备份…”撤销。接下来将重启 DSH；页面加载后请重新打开原会话。"
                completed.addButton(withTitle: "重新加载页面")
                completed.addButton(withTitle: "显示原始备份")
                if completed.runModal() == .alertSecondButtonReturn, let manifest = result.manifest {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: manifest)])
                }
            } catch {
                self.presentSessionOperationError(error)
            }
            self.isRepairingSession = false
            self.hideWebOperationStatus()
            if serviceStopped { self.restartDeepSeekHarness(using: runtime, preferredVersion: version) }
        }
    }

    func restoreSessionBackup() {
        guard !isLaunchingDeepSeekHarness, !isUpdateOperationInProgress,
              let version = activeDSHVersion ?? runtimeManager.preferredRuntimeVersion(),
              case let .ready(runtime) = NodeRuntimeDetector().detect(preferredNodeURL: preferredNodeURL)
        else { return }
        let panel = NSOpenPanel()
        panel.title = "恢复会话原始备份"
        panel.message = "选择会话备份的 JSON 记录。恢复会保留当前日志副本；原始会话可能需要新版 DSH 才能读取。"
        panel.allowedFileTypes = ["json"]
        panel.directoryURL = try? runtimeManager.sessionBackupsDirectory()
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let manifest = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "恢复原始会话日志？"
        alert.informativeText = "将校验备份完整性，备份当前日志，再恢复原始压缩日志并重启 DSH。若修复后已有新消息，将停止恢复以避免覆盖。请先结束其他会话中的运行任务。"
        alert.addButton(withTitle: "恢复备份")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        isRepairingSession = true
        cancelWebRecovery()
        showWebOperationStatus("正在校验并恢复原始备份…")
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.runtimeManager.operateOnSession(
                    action: "restore", manifest: manifest, version: version, using: runtime
                )
                let completed = NSAlert()
                completed.messageText = "已恢复原始日志"
                completed.informativeText = "原始压缩日志已按备份完整恢复，修复后的版本也已备份。若当前 DSH 无法读取，请切换回创建该会话的新版 DSH。"
                completed.runModal()
            } catch { self.presentSessionOperationError(error) }
            self.isRepairingSession = false
            self.hideWebOperationStatus()
            self.restartDeepSeekHarness(using: runtime, preferredVersion: version)
        }
    }

    private func presentSessionOperationError(_ error: Error) {
        hideWebOperationStatus()
        let alert = NSAlert()
        alert.messageText = "会话操作未完成"
        // Process/codec errors can contain private data. Only our fixed diagnostics are displayed.
        alert.informativeText = (error as? DSHSessionRepairError)?.localizedDescription
            ?? DSHSessionRepairError(code: "operationFailed").localizedDescription
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "查看备份")
        if alert.runModal() == .alertSecondButtonReturn,
           let directory = try? runtimeManager.sessionBackupsDirectory() {
            NSWorkspace.shared.open(directory)
        }
    }

    private func registerWorkspaceDrop2AddBridge(_ payload: [String: Any]) {
        guard let action = payload["action"] as? String else { return }
        if action == "ready" {
            guard let token = payload["token"] as? String,
                  UUID(uuidString: token) != nil
            else {
                return
            }
            workspaceDrop2AddBridgeToken = token
            webView.isWorkspaceDrop2AddBridgeReady = true
            installWorkspaceDrop2AddPageProtection()
            return
        }

        guard action == "sidebar-layout",
              payload["token"] as? String == workspaceDrop2AddBridgeToken,
              let width = payload["width"] as? NSNumber
        else {
            return
        }
        webView.sidebarDrop2AddWidth = min(max(0, CGFloat(width.doubleValue)), webView.bounds.width)
        updateWorkspaceDrop2AddPageProtection(width: webView.sidebarDrop2AddWidth)
    }

    private func resetWorkspaceDrop2AddBridge() {
        workspaceDrop2AddBridgeToken = nil
        webView.isWorkspaceDrop2AddBridgeReady = false
        webView.sidebarDrop2AddWidth = 0
        updateWorkspaceDrop2AddPageProtection(width: 0, enabled: false)
    }

    private func receiveTaskNotificationBridge(_ payload: [String: Any]) {
        guard let token = payload["token"] as? String,
              UUID(uuidString: token) != nil,
              let kind = payload["kind"] as? String else { return }
        if kind == "ready" {
            taskNotificationBridgeToken = token
            deliverPendingNotificationSession()
            return
        }
        guard token == taskNotificationBridgeToken,
              let sessionId = payload["sessionId"] as? String,
              let key = payload["key"] as? String
        else { return }
        onTaskNotification?(kind, sessionId, key)
    }

    func openDSHSession(_ sessionId: String) {
        pendingNotificationSessionId = sessionId
        deliverPendingNotificationSession()
    }

    private func deliverPendingNotificationSession() {
        guard let sessionId = pendingNotificationSessionId,
              taskNotificationBridgeToken != nil,
              let data = try? JSONSerialization.data(withJSONObject: sessionId, options: .fragmentsAllowed),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__dshForMacTaskNotifications?.open(\(json));") { [weak self] _, error in
            guard error == nil else { return }
            if self?.pendingNotificationSessionId == sessionId {
                self?.pendingNotificationSessionId = nil
            }
        }
    }

    private func deliverWorkspaceDirectory(_ directoryURL: URL) {
        guard let token = workspaceDrop2AddBridgeToken else { return }
        let payload: [String: String] = [
            "token": token,
            "path": directoryURL.path,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else {
            return
        }
        webView.evaluateJavaScript("window.__dshForMacWorkspaceDrop2Add?.receive(\(json));") { _, error in
            if let error {
                NSLog("Unable to deliver Finder folder to DSH plugin: \(error.localizedDescription)")
            }
        }
    }

    private func openExternalURL(_ url: URL) {
        let alert = NSAlert()
        if url.isFileURL {
            alert.messageText = "使用默认应用打开文件？"
            alert.informativeText = url.path
            alert.addButton(withTitle: "打开")
        } else {
            alert.messageText = "在浏览器中打开链接？"
            alert.informativeText = url.absoluteString
            alert.addButton(withTitle: "打开浏览器")
        }
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.open(url)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping NavigationActionDecisionHandler
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        guard !isLocalDSHURL(url) else {
            decisionHandler(.allow)
            return
        }

        openExternalURL(url)
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        resetWorkspaceDrop2AddBridge()
        taskNotificationBridgeToken = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        hideWebOperationStatus()
        if webRecoveryNeeded, let activeDSHVersion {
            webRecoveryNeeded = false
            failedWebLoads = 0
            reportServiceStatus("运行中 · \(activeDSHVersion)", isRunning: true)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleWebNavigationFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleWebNavigationFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        handleWebNavigationFailure(nil)
    }

    private func handleWebNavigationFailure(_ error: Error?) {
        if let error = error as NSError?, error.domain == NSURLErrorDomain,
           error.code == NSURLErrorCancelled { return }
        guard activeDSHVersion != nil, !isLaunchingDeepSeekHarness else { return }
        failedWebLoads += 1
        webRecoveryNeeded = true
        if failedWebLoads >= 2 {
            cancelWebRecovery()
            showWebConnectionFailure()
        } else {
            startWebRecovery()
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }

        if isLocalDSHURL(url) {
            webView.load(navigationAction.request)
        } else {
            openExternalURL(url)
        }
        return nil
    }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var owner: MainViewController?

    init(owner: MainViewController) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.userContentController(userContentController, didReceive: message)
    }
}

private extension NodeRuntimeStatus {
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}
