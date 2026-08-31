import AppKit
import ImageIO
import WebKit

final class FilePreviewViewController: NSViewController, WKNavigationDelegate {
    var onClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "预览")
    private let detailLabel = NSTextField(labelWithString: "选择 DSH 产出物以查看")
    private let closeButton = PreviewActionButton(title: "", target: nil, action: nil)
    private let openInDefaultAppButton = PreviewActionButton(title: "", target: nil, action: nil)
    private let contentContainer = NSView()
    private let textView = NSTextView()
    private let textScrollView = NSScrollView()
    private let textPreviewContainer = NSView()
    private let lineNumberTextView = NSTextView()
    private let lineNumberScrollView = NSScrollView()
    private let imageView = NSImageView()
    private let imageScrollView = NSScrollView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "选择 DSH 产出物以查看")
    private lazy var webPreview: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let preview = WKWebView(frame: .zero, configuration: configuration)
        preview.navigationDelegate = self
        return preview
    }()

    private var sourceURL: URL?
    private var requestedKind: PreviewContentKind?
    private var displayFileName: String?
    private var currentTask: URLSessionDataTask?
    private var requestIdentifier = UUID()
    private let previewDownloadDelegate = PreviewDownloadDelegate()
    private lazy var previewSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(
            configuration: configuration,
            delegate: previewDownloadDelegate,
            delegateQueue: nil
        )
    }()

    private static let maximumPreviewBytes = 20 * 1_024 * 1_024
    private static let maximumHighlightedCharacters = 1_000_000
    private static let maximumImagePixels = 50_000_000

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        showMessage("选择 DSH 产出物以查看")
    }

    func preview(url: URL, kind: PreviewContentKind? = nil, fileName: String? = nil) {
        currentTask?.cancel()
        sourceURL = url
        requestedKind = kind
        displayFileName = fileName ?? PreviewContentKind.sourceFileName(for: url)
        let identifier = UUID()
        requestIdentifier = identifier
        titleLabel.stringValue = displayFileName?.isEmpty == false ? displayFileName! : "预览"
        detailLabel.stringValue = "正在加载…"
        openInDefaultAppButton.isEnabled = true
        showMessage("正在加载预览…")

        if url.isFileURL {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try Data(contentsOf: url, options: .mappedIfSafe) }
                DispatchQueue.main.async {
                    self?.apply(result: result, url: url, mimeType: nil, identifier: identifier)
                }
            }
            return
        }

        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        currentTask = previewSession.dataTask(with: request) { [weak self] data, response, error in
            let result: Result<Data, Error>
            if let error {
                result = .failure(error)
            } else if let responseURL = response?.url, !Self.hasSameOrigin(responseURL, url) {
                result = .failure(PreviewError.untrustedRedirect)
            } else if let data {
                result = .success(data)
            } else {
                result = .failure(PreviewError.missingData)
            }
            DispatchQueue.main.async {
                self?.apply(
                    result: result,
                    url: url,
                    mimeType: response?.mimeType,
                    identifier: identifier
                )
            }
        }
        currentTask?.resume()
    }

    private func configureView() {
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 3

        closeButton.title = "关闭"
        closeButton.symbol = actionSymbolImage(
            named: "xmark",
            accessibilityDescription: "关闭预览"
        )
        configureActionButton(closeButton)
        closeButton.textFont = .systemFont(ofSize: 13, weight: .regular)
        closeButton.target = self
        closeButton.action = #selector(closePreview)
        closeButton.toolTip = "关闭预览"

        openInDefaultAppButton.title = "默认应用"
        openInDefaultAppButton.symbol = actionSymbolImage(
            named: "arrow.up.forward.app",
            accessibilityDescription: "使用默认应用打开"
        )
        configureActionButton(openInDefaultAppButton)
        openInDefaultAppButton.textFont = .systemFont(ofSize: 13, weight: .regular)
        openInDefaultAppButton.target = self
        openInDefaultAppButton.action = #selector(openInDefaultApp)
        openInDefaultAppButton.toolTip = "使用默认应用打开"
        openInDefaultAppButton.isEnabled = false

        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let actions = NSStackView(views: [openInDefaultAppButton, closeButton])
        actions.orientation = .horizontal
        actions.spacing = 4

        let header = NSStackView(views: [labels, NSView(), actions])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(contentContainer)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            closeButton.heightAnchor.constraint(equalToConstant: 34),
            openInDefaultAppButton.heightAnchor.constraint(equalToConstant: 34),
        ])

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindPanel = true
        textView.usesFontPanel = false
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.backgroundColor = .textBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.minSize = NSSize(width: 320, height: 1)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: 0, width: 320, height: 1)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        textScrollView.hasVerticalScroller = true
        textScrollView.hasHorizontalScroller = true
        textScrollView.autohidesScrollers = true
        textScrollView.borderType = .noBorder
        textScrollView.documentView = textView

        lineNumberTextView.isEditable = false
        lineNumberTextView.isSelectable = false
        lineNumberTextView.isRichText = false
        lineNumberTextView.drawsBackground = true
        lineNumberTextView.backgroundColor = .textBackgroundColor
        lineNumberTextView.textContainerInset = NSSize(width: 6, height: 14)
        lineNumberTextView.isVerticallyResizable = true
        lineNumberTextView.isHorizontallyResizable = false
        lineNumberTextView.minSize = NSSize(width: 44, height: 1)
        lineNumberTextView.maxSize = NSSize(width: 44, height: CGFloat.greatestFiniteMagnitude)
        lineNumberTextView.frame = NSRect(x: 0, y: 0, width: 44, height: 1)
        lineNumberTextView.textContainer?.widthTracksTextView = true

        lineNumberScrollView.hasVerticalScroller = false
        lineNumberScrollView.hasHorizontalScroller = false
        lineNumberScrollView.autohidesScrollers = true
        lineNumberScrollView.borderType = .noBorder
        lineNumberScrollView.documentView = lineNumberTextView

        textPreviewContainer.translatesAutoresizingMaskIntoConstraints = false
        lineNumberScrollView.translatesAutoresizingMaskIntoConstraints = false
        textScrollView.translatesAutoresizingMaskIntoConstraints = false
        textPreviewContainer.addSubview(lineNumberScrollView)
        textPreviewContainer.addSubview(textScrollView)
        NSLayoutConstraint.activate([
            lineNumberScrollView.leadingAnchor.constraint(equalTo: textPreviewContainer.leadingAnchor),
            lineNumberScrollView.topAnchor.constraint(equalTo: textPreviewContainer.topAnchor),
            lineNumberScrollView.bottomAnchor.constraint(equalTo: textPreviewContainer.bottomAnchor),
            lineNumberScrollView.widthAnchor.constraint(equalToConstant: 44),
            textScrollView.leadingAnchor.constraint(equalTo: lineNumberScrollView.trailingAnchor),
            textScrollView.trailingAnchor.constraint(equalTo: textPreviewContainer.trailingAnchor),
            textScrollView.topAnchor.constraint(equalTo: textPreviewContainer.topAnchor),
            textScrollView.bottomAnchor.constraint(equalTo: textPreviewContainer.bottomAnchor),
        ])
        textScrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textScrollBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: textScrollView.contentView
        )

        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageScrollView.hasVerticalScroller = true
        imageScrollView.hasHorizontalScroller = true
        imageScrollView.autohidesScrollers = true
        imageScrollView.allowsMagnification = true
        imageScrollView.minMagnification = 0.1
        imageScrollView.maxMagnification = 8
        imageScrollView.documentView = imageView
    }

    private func apply(
        result: Result<Data, Error>,
        url: URL,
        mimeType: String?,
        identifier: UUID
    ) {
        guard identifier == requestIdentifier else { return }
        currentTask = nil
        switch result {
        case let .failure(error):
            detailLabel.stringValue = "无法读取文件"
            showMessage(error.localizedDescription)
        case let .success(data):
            guard data.count <= Self.maximumPreviewBytes else {
                detailLabel.stringValue = "文件过大"
                showMessage("文件超过 20 MB，未在应用内加载。可使用默认应用打开。")
                return
            }
            var kind = requestedKind ?? PreviewContentKind.detect(url: url, mimeType: mimeType)
            // DSH 产物的脚本未必都有常规扩展名。只要内容可安全解码为文本，
            // 仍以只读文本方式预览；不会执行其中的任何代码。
            if kind == .unsupported, decodeText(from: data) != nil {
                kind = .text
            }
            show(data: data, as: kind, fileName: displayFileName ?? PreviewContentKind.sourceFileName(for: url))
        }
    }

    private func show(data: Data, as kind: PreviewContentKind, fileName: String) {
        switch kind {
        case .image:
            showImage(data: data, fileName: fileName)
        case .svg:
            showSVG(data: data)
        case .markdown:
            guard let text = decodeText(from: data) else {
                showUnsupportedText()
                return
            }
            detailLabel.stringValue = "Markdown 预览"
            showWebHTML(MarkdownRenderer.render(text))
        case .text:
            guard let text = decodeText(from: data) else {
                showUnsupportedText()
                return
            }
            let isLargeText = text.count > Self.maximumHighlightedCharacters
            detailLabel.stringValue = isLargeText ? "文本预览 · 已关闭高亮（文件较大）" : "只读文本预览"
            textView.textStorage?.setAttributedString(
                isLargeText
                    ? NSAttributedString(
                        string: text,
                        attributes: [
                            .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                            .foregroundColor: NSColor.labelColor,
                        ]
                    )
                    : GenericSyntaxHighlighter.attributedText(for: text, fileName: fileName)
            )
            sizeTextDocumentView()
            updateLineNumbers(for: text)
            textScrollView.contentView.scroll(to: .zero)
            lineNumberScrollView.contentView.scroll(to: .zero)
            showContent(textPreviewContainer)
        case .unsupported:
            detailLabel.stringValue = "不支持的文件类型"
            showMessage("暂不支持在应用内预览此文件。可使用默认应用打开。")
        }
    }

    private func showImage(data: Data, fileName: String) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue * height.intValue <= Self.maximumImagePixels,
              let image = NSImage(data: data)
        else {
            detailLabel.stringValue = "无法安全地预览图片"
            showMessage("图片无效或像素尺寸过大。可使用默认应用打开。")
            return
        }

        let size = image.size
        let scale = min(1, 2_000 / max(size.width, size.height, 1))
        imageView.frame = NSRect(origin: .zero, size: NSSize(width: size.width * scale, height: size.height * scale))
        imageView.image = image
        imageScrollView.magnification = 1
        detailLabel.stringValue = "图片预览 · \(width.intValue) × \(height.intValue)"
        showContent(imageScrollView)
    }

    private func showSVG(data: Data) {
        guard let svg = decodeText(from: data) else {
            detailLabel.stringValue = "无法读取 SVG"
            showMessage("SVG 不是有效的文本内容。可使用默认应用打开。")
            return
        }
        detailLabel.stringValue = "SVG 预览 · 已隔离执行内容"
        let html = """
        <!doctype html><html><head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'none'">
        <style>:root { color-scheme: light dark; } html,body { width:100%; height:100%; margin:0; } body { display:grid; place-items:center; background:Canvas; } svg { max-width:100%; max-height:100%; }</style>
        </head><body>\(svg)</body></html>
        """
        showWebHTML(html)
    }

    private func showUnsupportedText() {
        detailLabel.stringValue = "无法识别文本编码"
        showMessage("该文件不是受支持的文本编码。可使用默认应用打开。")
    }

    private func showWebHTML(_ html: String) {
        webPreview.loadHTMLString(html, baseURL: nil)
        showContent(webPreview)
    }

    private func showMessage(_ message: String) {
        messageLabel.stringValue = message
        showContent(messageLabel)
    }

    private func showContent(_ content: NSView) {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        content.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            content.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            content.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    private func sizeTextDocumentView() {
        guard let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager
        else { return }

        layoutManager.ensureLayout(for: textContainer)
        let usedSize = layoutManager.usedRect(for: textContainer).size
        textView.frame.size = NSSize(
            width: max(320, ceil(usedSize.width + textView.textContainerInset.width * 2)),
            height: max(1, ceil(usedSize.height + textView.textContainerInset.height * 2))
        )
    }

    private func updateLineNumbers(for text: String) {
        let lineCount = max(1, text.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        })
        let lineNumbers = (1...lineCount).map(String.init).joined(separator: "\n")
        lineNumberTextView.textStorage?.setAttributedString(
            NSAttributedString(
                string: lineNumbers,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]
            )
        )
        lineNumberTextView.frame.size.height = textView.frame.height
    }

    private func syncLineNumberScrollPosition() {
        let origin = textScrollView.contentView.bounds.origin
        lineNumberScrollView.contentView.scroll(to: NSPoint(x: 0, y: origin.y))
        lineNumberScrollView.reflectScrolledClipView(lineNumberScrollView.contentView)
    }

    @objc private func textScrollBoundsDidChange() {
        syncLineNumberScrollPosition()
    }

    private func configureActionButton(_ button: PreviewActionButton) {
        button.applyVisualStyle()
    }

    private func actionSymbolImage(named name: String, accessibilityDescription: String) -> NSImage? {
        guard let symbol = NSImage(
            systemSymbolName: name,
            accessibilityDescription: accessibilityDescription
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        else {
            return nil
        }

        return symbol
    }

    private func decodeText(from data: Data) -> String? {
        guard !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .unicode)
            ?? String(data: data, encoding: .isoLatin1)
    }

    nonisolated private static func hasSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme == rhs.scheme && lhs.host == rhs.host && lhs.port == rhs.port
    }

    @objc private func closePreview() {
        onClose?()
    }

    @objc private func openInDefaultApp() {
        guard let sourceURL else { return }
        NSWorkspace.shared.open(sourceURL)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let allowsInitialDocumentLoad = navigationAction.navigationType == .other
            && navigationAction.request.url?.scheme == "about"
        decisionHandler(allowsInitialDocumentLoad ? .allow : .cancel)
    }
}

private final class PreviewActionButton: NSControl {
    var title: String {
        didSet {
            titleLabel.stringValue = title
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }
    var symbol: NSImage? {
        didSet {
            symbolView.image = symbol
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }
    var textFont: NSFont {
        didSet {
            titleLabel.font = textFont
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let symbolView = NSImageView()
    private var isPressing = false
    private var isHovering = false

    override init(frame frameRect: NSRect) {
        title = ""
        textFont = .systemFont(ofSize: 13, weight: .regular)
        super.init(frame: frameRect)
        configureSubviews()
        applyVisualStyle()
    }

    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
    }

    required init?(coder: NSCoder) {
        title = ""
        textFont = .systemFont(ofSize: 13, weight: .regular)
        super.init(coder: coder)
        configureSubviews()
        applyVisualStyle()
    }

    override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1 : 0.45
            updateBackgroundColor()
        }
    }

    override var intrinsicContentSize: NSSize {
        let titleWidth = titleLabel.intrinsicContentSize.width
        let symbolWidth = symbol?.size.width ?? 0
        let gap: CGFloat = symbol == nil ? 0 : 6
        return NSSize(width: ceil(12 + titleWidth + gap + symbolWidth + 12), height: 34)
    }

    override func layout() {
        super.layout()
        let titleSize = titleLabel.intrinsicContentSize
        let symbolSize = symbol?.size ?? .zero
        let titleY = floor((bounds.height - titleSize.height) / 2)
        titleLabel.frame = NSRect(x: 12, y: titleY, width: titleSize.width, height: titleSize.height)
        symbolView.frame = NSRect(
            x: titleLabel.frame.maxX + (symbol == nil ? 0 : 6),
            y: floor((bounds.height - symbolSize.height) / 2),
            width: symbolSize.width,
            height: symbolSize.height
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressing = true
        updateBackgroundColor()
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressing else { return }
        isPressing = false
        updateBackgroundColor()
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location) else { return }
        sendAction(action, to: target)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        isHovering = true
        updateBackgroundColor()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        isPressing = false
        updateBackgroundColor()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isEnabled else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    func applyVisualStyle() {
        wantsLayer = true
        layer?.cornerRadius = 17
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 0.88, alpha: 1).cgColor
        titleLabel.font = textFont
        titleLabel.textColor = .labelColor
        symbolView.contentTintColor = .labelColor
        updateBackgroundColor()
    }

    private func configureSubviews() {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.imageScaling = .scaleNone
        addSubview(titleLabel)
        addSubview(symbolView)
    }

    private func updateBackgroundColor() {
        let color: NSColor
        if !isEnabled {
            color = NSColor(calibratedWhite: 1, alpha: 1)
        } else if isPressing {
            color = NSColor(calibratedWhite: 0.90, alpha: 1)
        } else if isHovering {
            color = NSColor(calibratedWhite: 0.96, alpha: 1)
        } else {
            color = NSColor(calibratedWhite: 1, alpha: 1)
        }
        layer?.backgroundColor = color.cgColor
    }
}

private enum PreviewError: LocalizedError {
    case missingData
    case untrustedRedirect

    var errorDescription: String? {
        switch self {
        case .missingData:
            "预览服务没有返回文件内容。"
        case .untrustedRedirect:
            "预览链接重定向到了不受信任的地址。"
        }
    }
}

private final class PreviewDownloadDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let originalURL = task.originalRequest?.url,
              let redirectedURL = request.url,
              redirectedURL.scheme == originalURL.scheme,
              redirectedURL.host == originalURL.host,
              redirectedURL.port == originalURL.port
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
