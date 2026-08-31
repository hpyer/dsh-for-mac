import AppKit
import WebKit

final class MainViewController: NSViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    var onServiceStatusChanged: ((String, Bool) -> Void)?
    var onUpdateCheckStatusChanged: ((String) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "DeepSeek Harness for Mac")
    private let statusLabel = NSTextField(labelWithString: "正在检测 Node.js…")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let primaryButton = NSButton(title: "重新检测", target: nil, action: nil)
    private let redownloadButton = NSButton(title: "重新下载 DSH", target: nil, action: nil)
    private let chooseNodeButton = NSButton(title: "选择 Node.js 路径", target: nil, action: nil)
    private let nodeWebsiteButton = NSButton(title: "打开 Node.js 官网", target: nil, action: nil)
    private let environmentStack = NSStackView()
    private let previewContainer = NSView()
    private let previewBridgeToken = UUID().uuidString
    private lazy var filePreviewViewController: FilePreviewViewController = {
        let controller = FilePreviewViewController()
        controller.onClose = { [weak self] in
            self?.closeFilePreview()
        }
        return controller
    }()
    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(
            WeakScriptMessageHandler(owner: self),
            name: Self.producedFilePreviewHandlerName
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
                forMainFrameOnly: true
            )
        )
        configuration.userContentController = contentController
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        return webView
    }()
    private lazy var runtimeManager = DSHRuntimeManager { [weak self] status in
        self?.statusLabel.stringValue = status
        guard let self else { return }
        if self.isLaunchingDeepSeekHarness {
            self.reportStartupStatus(status)
        } else {
            self.reportServiceStatus(status, isRunning: false)
        }
    }
    private var didShowMissingNodeAlert = false
    private var isLaunchingDeepSeekHarness = false
    private var didCompleteInitialStartup = false
    private var failedDSHVersion: String?
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

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        refreshRuntimeStatus()
    }

    private func configureView() {
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        statusLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 4

        primaryButton.target = self
        primaryButton.action = #selector(primaryButtonPressed)
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
                self.failedDSHVersion = nil
                self.showWebInterface(at: result.address)
                self.reportServiceStatus("运行中 · \(result.version)", isRunning: true)
                self.scheduleUpdateCheckIfNeeded(using: runtime)
            } catch {
                self.isLaunchingDeepSeekHarness = false
                self.failedDSHVersion = self.runtimeManager.preferredRuntimeVersion()
                self.showStartupError(error)
            }
        }
    }

    private func restartDeepSeekHarness(using runtime: NodeRuntime) {
        guard !isLaunchingDeepSeekHarness else { return }
        isLaunchingDeepSeekHarness = true
        primaryButton.isEnabled = false
        redownloadButton.isEnabled = false
        statusLabel.stringValue = "正在重启 DSH…"
        detailLabel.stringValue = "将直接重启当前 DSH 版本，不检查更新。"
        reportStartupStatus("正在重启 DSH…")

        let version = activeDSHVersion ?? failedDSHVersion
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.runtimeManager.restart(using: runtime, preferredVersion: version)
                self.isLaunchingDeepSeekHarness = false
                self.activeDSHVersion = result.version
                self.failedDSHVersion = nil
                self.showWebInterface(at: result.address)
                self.reportServiceStatus("运行中 · \(result.version)", isRunning: true)
            } catch {
                self.isLaunchingDeepSeekHarness = false
                self.failedDSHVersion = self.runtimeManager.preferredRuntimeVersion()
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

    func stopDeepSeekHarness() {
        runtimeManager.stop()
        activeDSHVersion = nil
        reportServiceStatus("DSH 已停止", isRunning: false)
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
        restartDeepSeekHarness()
    }

    func installedDSHVersions() -> [String] {
        runtimeManager.installedVersions()
    }

    func openRuntimeVersionsDirectory() {
        guard let directory = runtimeManager.runtimeVersionsDirectoryURL() else { return }
        NSWorkspace.shared.open(directory)
    }

    func checkForUpdatesNow() {
        guard case let .ready(runtime) = NodeRuntimeDetector().detect(preferredNodeURL: preferredNodeURL) else {
            onUpdateCheckStatusChanged?("失败：Node.js 尚未就绪，无法检查 DSH 更新。")
            return
        }
        performUpdateCheck(using: runtime)
    }

    @objc private func refreshRuntimeStatus() {
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
        webView.stopLoading()
        webView.isHidden = true
        closeFilePreview()
        environmentStack.isHidden = false
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
                self.failedDSHVersion = nil
                self.showWebInterface(at: result.address)
                self.reportServiceStatus("运行中 · \(result.version)", isRunning: true)
            } catch {
                self.isLaunchingDeepSeekHarness = false
                self.failedDSHVersion = self.runtimeManager.preferredRuntimeVersion()
                self.showStartupError(error)
            }
        }
    }

    private func scheduleUpdateCheckIfNeeded(using runtime: NodeRuntime) {
        guard AppSettings.shared.shouldCheckForUpdates() else { return }
        performUpdateCheck(using: runtime)
    }

    private func performUpdateCheck(using runtime: NodeRuntime) {
        onUpdateCheckStatusChanged?("正在检查更新…")
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.runtimeManager.checkForUpdates(
                    using: runtime,
                    reportsProgress: false
                )
                AppSettings.shared.lastUpdateCheckDate = Date()
                let message: String
                switch result {
                case let .downloaded(version):
                    message = "有新版本 \(version)，已下载。"
                case let .alreadyInstalled(version):
                    message = "已是最新版本（\(version)）。"
                }
                self.onUpdateCheckStatusChanged?(message)
            } catch {
                self.onUpdateCheckStatusChanged?("失败：\(error.localizedDescription)")
            }
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
        """
        (() => {
          const bridge = window.webkit?.messageHandlers?.\(Self.producedFilePreviewHandlerName);
          if (!bridge || window.__dshForMacProducedFilePreviewInstalled) return;
          window.__dshForMacProducedFilePreviewInstalled = true;

          var pendingClick = null;
          const originalFetch = window.fetch.bind(window);
          document.addEventListener('click', (event) => {
            if (!event.isTrusted) return;
            const target = event.target instanceof Element
              ? event.target.closest('[data-produced-files-row] button[title], [data-tool] button[class*="fileLink"], button[title][aria-label*="打开"], button[title][aria-label*="Open"]')
              : null;
            if (target) pendingClick = { expiresAt: Date.now() + 1_500 };
          }, true);

          window.fetch = function(input, init) {
            const requestURL = input instanceof Request ? input.url : String(input);
            const isOpenPathRequest = new URL(requestURL, window.location.href).pathname.endsWith('/api/host.openPath');
            if (!pendingClick || pendingClick.expiresAt < Date.now() || !isOpenPathRequest) {
              return originalFetch(input, init);
            }

            return Promise.resolve().then(async () => {
              const body = typeof init?.body === 'string'
                ? init.body
                : input instanceof Request
                  ? await input.clone().text()
                  : '';
              const request = JSON.parse(body);
              const path = request?.payload?.path;
              if (request?.type !== 'client-request' || typeof request?.rpcId !== 'string' || typeof path !== 'string' || path.length === 0) {
                return originalFetch(input, init);
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
            }).catch(() => originalFetch(input, init));
          };
        })();
        """
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
        guard message.name == Self.producedFilePreviewHandlerName,
              message.frameInfo.isMainFrame,
              let payload = message.body as? [String: Any],
              payload["token"] as? String == previewBridgeToken,
              let path = payload["path"] as? String,
              path.hasPrefix("/")
        else {
            return
        }
        showFilePreview(for: URL(fileURLWithPath: path).standardizedFileURL)
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

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        let response = navigationResponse.response
        guard let url = response.url,
              pendingPreviewResponseURLs.remove(url) != nil,
              isLocalDSHURL(url),
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
