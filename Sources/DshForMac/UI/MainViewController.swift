import AppKit
import WebKit

final class MainViewController: NSViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    var onServiceStatusChanged: ((String, Bool) -> Void)?
    var onUpdateCheckStatusChanged: ((String) -> Void)?
    var onUpdateAvailableVersionChanged: ((String?) -> Void)?
    var onRecommendedPluginOperationStatusChanged: ((String, Bool) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "DeepSeek Harness for Mac")
    private let statusLabel = NSTextField(labelWithString: "正在检测 Node.js…")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let primaryButton = NSButton(title: "重新检测", target: nil, action: nil)
    private let rollbackButton = NSButton(title: "退回上一版本", target: nil, action: nil)
    private let redownloadButton = NSButton(title: "重新下载 DSH", target: nil, action: nil)
    private let chooseNodeButton = NSButton(title: "选择 Node.js 路径", target: nil, action: nil)
    private let nodeWebsiteButton = NSButton(title: "打开 Node.js 官网", target: nil, action: nil)
    private let environmentStack = NSStackView()
    private let previewContainer = NSView()
    private let webOperationOverlay = NSVisualEffectView()
    private let webOperationLabel = NSTextField(labelWithString: "")
    private let webOperationSpinner = NSProgressIndicator()
    private let previewBridgeToken = UUID().uuidString
    private var workspaceDrop2AddBridgeToken: String?
    private lazy var filePreviewViewController: FilePreviewViewController = {
        let controller = FilePreviewViewController()
        controller.onClose = { [weak self] in
            self?.closeFilePreview()
        }
        return controller
    }()
    private lazy var webView: WorkspaceDrop2AddWebView = {
        let configuration = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(
            WeakScriptMessageHandler(owner: self),
            name: Self.producedFilePreviewHandlerName
        )
        contentController.add(
            WeakScriptMessageHandler(owner: self),
            name: Self.workspaceDrop2AddBridgeHandlerName
        )
        contentController.addUserScript(
            WKUserScript(
                source: webKitCompatibilityScript(),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        contentController.addUserScript(
            WKUserScript(
                source: producedFilePreviewBridgeScript(),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            )
        )
        configuration.userContentController = contentController
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
    var isUpdateOperationInProgress: Bool { isCheckingForUpdates || isDownloadingUpdate }
    var canDownloadUpdate: Bool {
        guard !isUpdateOperationInProgress, !isLaunchingDeepSeekHarness,
              let version = AppSettings.shared.availableUpdateVersion else { return false }
        return !AppSettings.shared.availableUpdateIsDownloaded || !installedDSHVersions().contains(version)
    }
    private var previewWidthConstraint: NSLayoutConstraint?
    private var pendingPreviewResponseURLs = Set<URL>()
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
    private static let producedFilePreviewHandlerName = "dshProducedFilePreview"
    private static let workspaceDrop2AddBridgeHandlerName = "dshWorkspaceDrop2AddBridge"

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
            self, selector: #selector(checkScheduledUpdates), name: NSWorkspace.didWakeNotification, object: nil
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
        guard !isLaunchingDeepSeekHarness else { return }
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
        environmentStack.isHidden = true
        if webView.superview == nil {
            webView.translatesAutoresizingMaskIntoConstraints = false
            previewContainer.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(webView)
            view.addSubview(previewContainer)
            configureWebOperationOverlay()

            let previewView = filePreviewViewController.view
            previewView.translatesAutoresizingMaskIntoConstraints = false
            previewContainer.addSubview(previewView)
            NSLayoutConstraint.activate([
                previewView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
                previewView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
                previewView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
                previewView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
            ])

            let previewWidthConstraint = previewContainer.widthAnchor.constraint(equalToConstant: 0)
            self.previewWidthConstraint = previewWidthConstraint
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                webView.topAnchor.constraint(equalTo: view.topAnchor),
                webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                webView.trailingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
                previewContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                previewContainer.topAnchor.constraint(equalTo: view.topAnchor),
                previewContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                previewWidthConstraint,
            ])
        }
        webView.isHidden = false
        webView.load(URLRequest(url: address))
    }

    private func showStartupError(_ error: Error) {
        activeDSHVersion = nil
        refreshRollbackButton()
        hideWebOperationStatus()
        showEnvironmentView()
        primaryButton.isEnabled = true
        redownloadButton.isEnabled = true
        chooseNodeButton.isHidden = true
        nodeWebsiteButton.isHidden = true
        statusLabel.stringValue = "DSH 启动失败"
        detailLabel.stringValue = error.localizedDescription
        primaryButton.title = "重新启动 DSH"
        primaryButton.isHidden = false
        redownloadButton.isHidden = false
        reportServiceStatus("DSH 启动失败", isRunning: false)
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
        reportServiceStatus("DSH 已退出（状态码 \(statusCode)）。", isRunning: false)
    }

    func stopDeepSeekHarness() {
        runtimeManager.stop()
        hideWebOperationStatus()
        activeDSHVersion = nil
        reportServiceStatus("DSH 已停止", isRunning: false)
    }

    func stopUpdateChecks() {
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
        guard let version = activeDSHVersion ?? runtimeManager.preferredRuntimeVersion() else {
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
            redownloadButton.isHidden = true
            chooseNodeButton.isHidden = true
            nodeWebsiteButton.isHidden = true
            if !didCompleteInitialStartup {
                didCompleteInitialStartup = true
                startDeepSeekHarness(using: runtime)
            }
        } else {
            primaryButton.isHidden = false
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
        webView.stopLoading()
        webView.isHidden = true
        closeFilePreview()
        environmentStack.isHidden = false
    }

    /// Uses the same presentation for an initial launch and a subsequent
    /// restart, rather than leaving a dimmed WebView visible underneath.
    private func showStartupProgress(status: String, detail: String) {
        rollbackButton.isHidden = true
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

    private func showFilePreview(
        for url: URL,
        kind: PreviewContentKind? = nil,
        fileName: String? = nil
    ) {
        previewContainer.isHidden = false
        let preferredWidth = min(520, max(280, view.bounds.width * 0.38))
        previewWidthConstraint?.constant = min(preferredWidth, max(220, view.bounds.width - 250))
        view.layoutSubtreeIfNeeded()
        filePreviewViewController.preview(url: url, kind: kind, fileName: fileName)
    }

    private func closeFilePreview() {
        guard previewWidthConstraint?.constant != 0 else { return }
        previewWidthConstraint?.constant = 0
        previewContainer.isHidden = true
        view.layoutSubtreeIfNeeded()
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
        let content = NSStackView(views: [webOperationSpinner, webOperationLabel])
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
        webOperationSpinner.startAnimation(nil)
        webOperationOverlay.isHidden = false
    }

    private func hideWebOperationStatus() {
        webOperationOverlay.isHidden = true
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

    private func performUpdateCheck(using runtime: NodeRuntime) {
        guard !isUpdateOperationInProgress else { return }
        let registry = AppSettings.shared.registry
        let additionalTag = AppSettings.shared.additionalUpdateTagEnabled ? AppSettings.shared.updateChannel : nil
        isCheckingForUpdates = true
        lastUpdateCheckAttempt = Date()
        onUpdateCheckStatusChanged?("正在检查更新…")
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
                let currentTag = AppSettings.shared.additionalUpdateTagEnabled ? AppSettings.shared.updateChannel : nil
                guard registry == AppSettings.shared.registry, additionalTag == currentTag else {
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
                    message = "当前已是最新版本。\(unavailableSuffix)"
                } else if result.isInstalled {
                    message = "新版本 \(result.version) 已下载。\(unavailableSuffix)"
                } else {
                    message = "发现新版本 \(result.version)，是否下载？\(unavailableSuffix)"
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
                self.onUpdateCheckStatusChanged?("新版本 \(version) 已下载，可在 DSH 版本中选择。")
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
            onUpdateCheckStatusChanged?("当前已是最新版本。")
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

    private func isPreviewableSourceURL(_ url: URL) -> Bool {
        url.isFileURL || (isLocalDSHURL(url) && PreviewContentKind.detect(url: url).isPreviewable)
    }

    private func producedFilePreviewBridgeScript() -> String {
        let openPathRequestPaths = ProducedFilePreviewBridge.openPathRequestPaths
            .sorted()
            .map { "\"\($0)\"" }
            .joined(separator: ", ")
        return """
        (() => {
          const bridge = window.webkit?.messageHandlers?.\(Self.producedFilePreviewHandlerName);
          if (!bridge || window.__dshForMacProducedFilePreviewInstalled) return;
          window.__dshForMacProducedFilePreviewInstalled = true;

          var pendingClick = null;
          const originalFetch = window.fetch.bind(window);
          const wrappedTransports = new WeakSet();
          document.addEventListener('click', (event) => {
            if (!event.isTrusted) return;
            const target = event.target instanceof Element
              ? event.target.closest('[data-produced-files-row] button[title], [data-tool] button[class*="fileLink"], button[title][aria-label*="打开"], button[title][aria-label*="Open"]')
              : null;
            if (!target) return;

            // DSH 0.1.2-rc.1 exposes an absolute file path in the title of
            // both produced-file chips and clickable mentions in a response.
            // Intercept them before React dispatches its handler, which would
            // otherwise invoke the system opener.
            const path = target.getAttribute('title');
            if (typeof path === 'string' && path.startsWith('/')) {
              event.preventDefault();
              event.stopImmediatePropagation();
              bridge.postMessage({ path, token: '\(previewBridgeToken)' });
              return;
            }

            // Links with a relative path are resolved by DSH before its RPC,
            // so retain the request-level interception as a fallback.
            pendingClick = { expiresAt: Date.now() + 1_500 };
          }, true);

          const interceptOpenPathRequest = function(delegate, input, init) {
            const requestURL = input instanceof Request ? input.url : String(input);
            const request = new URL(requestURL, window.location.href);
            const method = (init?.method ?? (input instanceof Request ? input.method : 'GET')).toUpperCase();
            const isMarketRestartRequest = request.origin === window.location.origin
              && request.pathname === '/dsh-market/restart'
              && method === 'POST';
            if (isMarketRestartRequest) {
              bridge.postMessage({ action: 'restart', token: '\(previewBridgeToken)' });
              return Promise.resolve(new Response(JSON.stringify({ ok: true, managed: true }), {
                status: 202,
                headers: { 'content-type': 'application/json' }
              }));
            }

            // DSH 0.1.2-rc.1 moved this capability from the host namespace to
            // the session namespace. Keep both Connection RPC routes so
            // previewing works with installed DSH versions on either side.
            const openPathRequestPaths = new Set([\(openPathRequestPaths)]);
            const rpcPath = new URL(requestURL, window.location.href).pathname;
            const isOpenPathRequest = openPathRequestPaths.has(rpcPath);
            if (!pendingClick || pendingClick.expiresAt < Date.now() || !isOpenPathRequest) {
              return delegate(input, init);
            }

            return Promise.resolve().then(async () => {
              const body = typeof init?.body === 'string'
                ? init.body
                : input instanceof Request
                  ? await input.clone().text()
                  : '';
              const request = JSON.parse(body);
              // Newer DSH Connection RPCs nest arguments under
              // payload.args, while the previous host route used payload.
              const path = request?.payload?.args?.request?.path ?? request?.payload?.path;
              if (request?.type !== 'client-request' || typeof request?.rpcId !== 'string' || typeof path !== 'string' || path.length === 0) {
                return delegate(input, init);
              }

              pendingClick = null;
              bridge.postMessage({ path, token: '\(previewBridgeToken)' });
              return new Response(JSON.stringify({
                type: 'server-response',
                rpcId: request.rpcId,
                result: { ok: true, value: { opened: true } }
              }), {
                status: 200,
                headers: { 'content-type': 'application/json' }
              });
            }).catch(() => delegate(input, init));
          };

          window.fetch = function(input, init) {
            return interceptOpenPathRequest(originalFetch, input, init);
          };

          // The current Web frontend may supply its own fetch implementation
          // through this boot-time transport. Wrap it as well: tool-call rows
          // and relative-path deliverables use that route to resolve the
          // session workspace before asking the host to open the file.
          const wrapTransportFetch = () => {
            const transport = window.__DSH_TRANSPORT__;
            if (!transport || typeof transport.fetch !== 'function' || wrappedTransports.has(transport)) return;
            const delegate = transport.fetch.bind(transport);
            transport.fetch = (input, init) => interceptOpenPathRequest(delegate, input, init);
            wrappedTransports.add(transport);
          };
          wrapTransportFetch();
          const transportWatcher = window.setInterval(wrapTransportFetch, 50);
          window.setTimeout(() => window.clearInterval(transportWatcher), 10_000);
        })();
        """
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

    /// Supplies Web APIs used by recent DSH web releases but absent from the
    /// WebKit shipped with older supported macOS versions (for example, macOS 13).
    private func webKitCompatibilityScript() -> String {
        """
        (() => {
          if (typeof AbortSignal === 'undefined' || typeof AbortController === 'undefined') return;

          const abortWithSourceReason = (controller, source) => {
            try {
              controller.abort(source && 'reason' in source ? source.reason : undefined);
            } catch (_) {
              controller.abort();
            }
          };

          if (typeof AbortSignal.timeout !== 'function') {
            AbortSignal.timeout = (milliseconds) => {
              const controller = new AbortController();
              const duration = Number(milliseconds);
              const delay = Number.isFinite(duration) ? Math.max(0, duration) : 0;
              window.setTimeout(() => {
                let reason;
                try {
                  reason = new DOMException('The operation timed out.', 'TimeoutError');
                } catch (_) {
                  reason = new Error('The operation timed out.');
                  reason.name = 'TimeoutError';
                }
                try {
                  controller.abort(reason);
                } catch (_) {
                  controller.abort();
                }
              }, delay);
              return controller.signal;
            };
          }

          if (typeof AbortSignal.any !== 'function') {
            AbortSignal.any = (signals) => {
              const sources = Array.from(signals);
              if (sources.some((source) => !source || typeof source.addEventListener !== 'function')) {
                throw new TypeError('AbortSignal.any expects AbortSignal instances.');
              }

              const controller = new AbortController();
              const listeners = [];
              let didAbort = false;
              const abortFrom = (source) => {
                if (didAbort) return;
                didAbort = true;
                listeners.forEach(({ signal, listener }) => signal.removeEventListener('abort', listener));
                abortWithSourceReason(controller, source);
              };

              for (const source of sources) {
                if (source.aborted) {
                  abortFrom(source);
                  return controller.signal;
                }
              }

              for (const source of sources) {
                const listener = () => abortFrom(source);
                listeners.push({ signal: source, listener });
                source.addEventListener('abort', listener, { once: true });
              }
              return controller.signal;
            };
          }
        })();
        """
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

        guard message.name == Self.producedFilePreviewHandlerName,
              payload["token"] as? String == previewBridgeToken
        else { return }

        if payload["action"] as? String == "restart" {
            restartDeepSeekHarness()
            return
        }

        guard let path = payload["path"] as? String,
              path.hasPrefix("/")
        else {
            return
        }
        showFilePreview(for: URL(fileURLWithPath: path).standardizedFileURL)
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
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        if isPreviewableSourceURL(url) {
            showFilePreview(for: url)
            decisionHandler(.cancel)
            return
        }

        if isLocalDSHURL(url) {
            pendingPreviewResponseURLs.insert(url)
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
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        hideWebOperationStatus()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        let response = navigationResponse.response
        guard let url = response.url,
              pendingPreviewResponseURLs.remove(url) != nil,
              isLocalDSHURL(url),
              url.path != "/",
              let mimeType = response.mimeType?.lowercased(),
              mimeType != "text/html",
              mimeType != "application/xhtml+xml"
        else {
            decisionHandler(.allow)
            return
        }

        let fileName = responseFileName(from: response) ?? PreviewContentKind.sourceFileName(for: url)
        let kind = PreviewContentKind.detect(fileName: fileName, mimeType: mimeType)
        showFilePreview(for: url, kind: kind, fileName: fileName)
        decisionHandler(.cancel)
    }

    private func responseFileName(from response: URLResponse) -> String? {
        guard let httpResponse = response as? HTTPURLResponse,
              let header = httpResponse.allHeaderFields.first(where: {
                  ($0.key as? String)?.caseInsensitiveCompare("Content-Disposition") == .orderedSame
              })?.value as? String
        else {
            return nil
        }
        for component in header.split(separator: ";") {
            let trimmed = component.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("filename=") {
                let value = trimmed.dropFirst("filename=".count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\\\""))
                return value.removingPercentEncoding ?? value
            }
            if trimmed.lowercased().hasPrefix("filename*=") {
                let value = String(trimmed.dropFirst("filename*=".count))
                let encodedValue = value.components(separatedBy: "''").last ?? value
                return encodedValue.removingPercentEncoding ?? encodedValue
            }
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }

        if isPreviewableSourceURL(url) {
            showFilePreview(for: url)
        } else if isLocalDSHURL(url) {
            pendingPreviewResponseURLs.insert(url)
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
