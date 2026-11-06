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
    private let playCompletionSound: () -> Void

    /// The card currently on screen. Exposed for appearance regression tests.
    var currentToastView: TaskReminderToastView? {
        toastPanel?.contentView as? TaskReminderToastView
    }

    init(playCompletionSound: (() -> Void)? = nil) {
        if let playCompletionSound {
            self.playCompletionSound = playCompletionSound
        } else {
            // Crystal is the display name since macOS 11; the system file keeps
            // its legacy Glass name. Load it directly to avoid user sound overrides.
            let sound = NSSound(contentsOfFile: "/System/Library/Sounds/Glass.aiff", byReference: true)
            self.playCompletionSound = { _ = sound?.play() }
        }
        super.init()
    }

    func receive(kind: String, sessionId: String, key: String, isAppVisible: Bool) {
        guard !isAppVisible, gate.accept(kind: kind, sessionId: sessionId, key: key) else { return }
        showToast(for: TaskReminder(kind: kind, sessionId: sessionId))
        if kind == "completed" { playCompletionSound() }
    }

    func sendTestReminder() {
        showToast(for: TaskReminder(kind: "test", sessionId: ""))
        playCompletionSound()
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
        let size = NSSize(width: TaskReminderToastView.width, height: TaskReminderToastView.height(isTest: isTest))
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let frame = NSRect(
            x: visible.maxX - size.width - 16,
            y: visible.maxY - size.height - 16,
            width: size.width,
            height: size.height
        )
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let toastView = TaskReminderToastView(reminder: reminder, isTest: isTest)
        toastView.frame = NSRect(origin: .zero, size: size)
        toastView.autoresizingMask = [.width, .height]
        toastView.onClose = { [weak self] in self?.dismissToast() }
        toastView.onOpen = { [weak self] in self?.openToast() }
        panel.contentView = toastView
        toastPanel = panel
        activeReminder = reminder
        panel.orderFrontRegardless()
        // Re-resolve once the card is attached to its panel so layer colors use
        // the panel's effective appearance rather than a construction-time one.
        toastView.refreshAppearanceDependentColors()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismissToast() }
        }
    }

    @objc private func openToast() {
        guard let reminder = activeReminder else { return }
        dismissToast()
        if reminder.kind != "test" { onOpenSession?(reminder.sessionId) }
    }
}
