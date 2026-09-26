import AppKit

struct TaskReminder: Equatable {
    let kind: String
    let sessionId: String

    var title: String {
        switch kind {
        case "attention": "DSH 任务需要处理"
        case "completed": "DSH 任务已完成"
        case "test": "DshForMac 测试提醒"
        default: "DSH 任务已结束"
        }
    }
}

struct TaskReminderGate {
    private var seenKeys = Set<String>()

    mutating func accept(kind: String, sessionId: String, key: String) -> Bool {
        guard ["attention", "completed", "ended"].contains(kind),
              !sessionId.isEmpty, sessionId.count <= 200,
              !key.isEmpty, key.count <= 300,
              !seenKeys.contains(key) else { return false }
        if seenKeys.count >= 512 { seenKeys.removeAll(keepingCapacity: true) }
        seenKeys.insert(key)
        return true
    }
}

@MainActor
final class TaskReminderController: NSObject {
    var onOpenSession: ((String) -> Void)?

    private var gate = TaskReminderGate()
    private var toastPanel: NSPanel?
    private var activeReminder: TaskReminder?
    private var toastTimer: Timer?

    func receive(kind: String, sessionId: String, key: String, isAppVisible: Bool) {
        guard !isAppVisible, gate.accept(kind: kind, sessionId: sessionId, key: key) else { return }
        showToast(for: TaskReminder(kind: kind, sessionId: sessionId))
    }

    func sendTestReminder() {
        showToast(for: TaskReminder(kind: "test", sessionId: ""))
    }

    func dismissToast() {
        toastTimer?.invalidate()
        toastTimer = nil
        toastPanel?.orderOut(nil)
        toastPanel = nil
        activeReminder = nil
    }

    private func showToast(for reminder: TaskReminder) {
        dismissToast()
        let isTest = reminder.kind == "test"
        let width: CGFloat = 330
        let height: CGFloat = isTest ? 72 : 104
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let frame = NSRect(x: visible.maxX - width - 16, y: visible.maxY - height - 16, width: width, height: height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = NSView(frame: NSRect(origin: .zero, size: frame.size))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor.cgColor

        let iconBackground = NSView()
        iconBackground.wantsLayer = true
        iconBackground.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        iconBackground.layer?.cornerRadius = 10
        iconBackground.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(iconBackground)

        let iconName: String
        switch reminder.kind {
        case "attention": iconName = "exclamationmark.bubble.fill"
        case "completed": iconName = "checkmark.circle.fill"
        default: iconName = "bell.fill"
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: iconName, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconBackground.addSubview(icon)

        let title = NSTextField(labelWithString: reminder.title)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(title)

        let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭提醒") ?? NSImage(), target: self, action: #selector(closeToast))
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "关闭提醒"
        closeButton.setAccessibilityLabel("关闭提醒")
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(closeButton)

        let detail = NSTextField(labelWithString: isTest
            ? "这是一条应用内测试提醒"
            : "点击下方按钮返回对应会话")
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 12)
        detail.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(detail)

        NSLayoutConstraint.activate([
            iconBackground.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            iconBackground.topAnchor.constraint(equalTo: background.topAnchor, constant: 18),
            iconBackground.widthAnchor.constraint(equalToConstant: 34),
            iconBackground.heightAnchor.constraint(equalToConstant: 34),
            icon.centerXAnchor.constraint(equalTo: iconBackground.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 17),
            icon.heightAnchor.constraint(equalToConstant: 17),
            title.leadingAnchor.constraint(equalTo: iconBackground.trailingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: background.topAnchor, constant: 16),
            title.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),
            closeButton.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            closeButton.topAnchor.constraint(equalTo: background.topAnchor, constant: 9),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -16),
        ])

        if !isTest {
            let openButton = NSButton(title: "打开会话", target: self, action: #selector(openToast))
            openButton.bezelStyle = .rounded
            openButton.controlSize = .small
            openButton.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(openButton)
            NSLayoutConstraint.activate([
                openButton.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                openButton.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 10),
            ])
        }
        panel.contentView = background
        toastPanel = panel
        activeReminder = reminder
        panel.orderFrontRegardless()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismissToast() }
        }
    }

    @objc private func openToast() {
        guard let reminder = activeReminder else { return }
        dismissToast()
        if reminder.kind != "test" { onOpenSession?(reminder.sessionId) }
    }

    @objc private func closeToast() {
        dismissToast()
    }
}
