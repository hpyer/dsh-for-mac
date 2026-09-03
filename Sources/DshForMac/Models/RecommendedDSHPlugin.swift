import Foundation

enum RecommendedDSHPlugin: String, CaseIterable, Sendable {
    case dshMarket
    case workspaceDrop2Add

    var packageName: String {
        switch self {
        case .dshMarket: "dshmarket"
        case .workspaceDrop2Add: "dsh-workspace-drop2add"
        }
    }

    var title: String {
        switch self {
        case .dshMarket: "DSH Market"
        case .workspaceDrop2Add: "拖入文件夹添加工作区"
        }
    }

    var detail: String {
        switch self {
        case .dshMarket: "在 DSH 内浏览和安装社区插件。"
        case .workspaceDrop2Add: "仅左侧栏接收 Finder 文件夹；右侧仍作为对话附件。"
        }
    }
}

struct RecommendedDSHPluginState: Equatable, Sendable {
    let plugin: RecommendedDSHPlugin
    let isEnabled: Bool
    let isAvailable: Bool
}
