import Foundation

enum RecommendedDSHPlugin: String, CaseIterable, Sendable {
    case dshMarket
    case workspaceDrop2Add
    case taskNotifications

    var isBundled: Bool { self != .dshMarket }

    /// The shared UI services used by the notification bridge are verified
    /// from DSH 0.1.5-rc.3 onward. The unified status API starts at 0.1.6-alpha.2.
    var minimumDSHVersion: String? { self == .taskNotifications ? "0.1.5-rc.3" : nil }

    func supportsDSHVersion(_ version: String) -> Bool {
        guard let minimumDSHVersion else { return true }
        guard let current = SemanticVersion(string: version),
              let minimum = SemanticVersion(string: minimumDSHVersion) else { return false }
        return current >= minimum
    }

    var packageName: String {
        switch self {
        case .dshMarket: "dshmarket"
        case .workspaceDrop2Add: "dsh-workspace-drop2add"
        case .taskNotifications: "dsh-task-notifications"
        }
    }

    var title: String {
        switch self {
        case .dshMarket: "DSH Market"
        case .workspaceDrop2Add: "拖入文件夹添加工作区"
        case .taskNotifications: "后台任务提醒"
        }
    }

    var detail: String {
        switch self {
        case .dshMarket: "在 DSH 内浏览和安装社区插件。"
        case .workspaceDrop2Add: "仅左侧栏接收 Finder 文件夹；右侧仍作为对话附件。"
        case .taskNotifications: "任务结束或需要处理时显示应用内提醒，点击返回会话。"
        }
    }
}

struct RecommendedDSHPluginState: Equatable, Sendable {
    let plugin: RecommendedDSHPlugin
    let isEnabled: Bool
    let isAvailable: Bool
}
