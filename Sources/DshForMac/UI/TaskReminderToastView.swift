import AppKit

/// Resolves a dynamic AppKit color for a concrete appearance.
///
/// `NSColor.cgColor` converts a dynamic catalog color using the *drawing*
/// appearance. Outside a drawing context AppKit resolves Aqua, so layer
/// colors created from `windowBackgroundColor` and friends stayed light even
/// while the window was drawn in dark mode. Resolve inside the target
/// appearance instead.
enum ReminderColorResolution {
    static func color(_ color: NSColor, for appearance: NSAppearance) -> NSColor {
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(cgColor: color.cgColor) ?? color
        }
        return resolved
    }
}

/// The floating card shown by `TaskReminderController`.
///
/// CALayer colors cannot hold dynamic `NSColor` values, so the surface,
/// border and icon chip colors are re-resolved from `effectiveAppearance`
/// whenever the system appearance changes. Text, buttons and symbol tints
/// keep dynamic AppKit colors so they adapt while drawing.
final class TaskReminderToastView: NSView {
    static let width: CGFloat = 330

    static func height(isTest: Bool) -> CGFloat {
        isTest ? 72 : 104
    }

    private enum Metrics {
        static let cornerRadius: CGFloat = 16
        static let borderWidth: CGFloat = 0.5
    }

    var onClose: (() -> Void)?
    var onOpen: (() -> Void)?

    private(set) var appliedSurfaceColor: NSColor = .clear
    private(set) var appliedBorderColor: NSColor = .clear
    private(set) var appliedIconBackgroundColor: NSColor = .clear

    private let iconBackground = NSView()
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let openButton: NSButton?

    init(reminder: TaskReminder, isTest: Bool) {
        openButton = isTest ? nil : NSButton(title: "打开会话", target: nil, action: nil)
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: Self.width, height: Self.height(isTest: isTest))))
        wantsLayer = true
        layer?.cornerRadius = Metrics.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = Metrics.borderWidth
        configureSubviews(reminder: reminder, isTest: isTest)
        refreshAppearanceDependentColors()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearanceDependentColors()
    }

    /// Re-resolves every layer color from the view's current appearance.
    func refreshAppearanceDependentColors() {
        let appearance = effectiveAppearance
        appliedSurfaceColor = ReminderColorResolution.color(.windowBackgroundColor, for: appearance)
        appliedBorderColor = ReminderColorResolution.color(.separatorColor, for: appearance)
        appliedIconBackgroundColor = ReminderColorResolution.color(
            NSColor.controlAccentColor.withAlphaComponent(0.14), for: appearance
        )
        layer?.backgroundColor = appliedSurfaceColor.cgColor
        layer?.borderColor = appliedBorderColor.cgColor
        iconBackground.layer?.backgroundColor = appliedIconBackgroundColor.cgColor
    }

    private func configureSubviews(reminder: TaskReminder, isTest: Bool) {
        iconBackground.wantsLayer = true
        iconBackground.layer?.cornerRadius = 11
        iconBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconBackground)

        let iconName: String
        switch reminder.kind {
        case "attention": iconName = "exclamationmark.bubble.fill"
        case "completed": iconName = "checkmark.circle.fill"
        default: iconName = "bell.fill"
        }
        icon.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) ?? NSImage()
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconBackground.addSubview(icon)

        titleLabel.stringValue = reminder.title
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        closeButton.image = (NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭提醒") ?? NSImage())
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.toolTip = "关闭提醒"
        closeButton.setAccessibilityLabel("关闭提醒")
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        detailLabel.stringValue = isTest ? "测试提醒与 Crystal 完成音" : "点击下方按钮返回对应会话"
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailLabel)

        var constraints = [
            iconBackground.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconBackground.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            iconBackground.widthAnchor.constraint(equalToConstant: 36),
            iconBackground.heightAnchor.constraint(equalToConstant: 36),
            icon.centerXAnchor.constraint(equalTo: iconBackground.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: iconBackground.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ]

        if let openButton {
            openButton.bezelStyle = .rounded
            openButton.controlSize = .small
            openButton.target = self
            openButton.action = #selector(openPressed)
            openButton.translatesAutoresizingMaskIntoConstraints = false
            addSubview(openButton)
            constraints.append(contentsOf: [
                openButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                openButton.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 10),
            ])
        }

        NSLayoutConstraint.activate(constraints)
    }

    @objc private func closePressed() {
        onClose?()
    }

    @objc private func openPressed() {
        onOpen?()
    }
}
