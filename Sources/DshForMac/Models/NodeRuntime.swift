import Foundation

struct NodeRuntime: Equatable, Sendable {
    let nodeURL: URL
    let npmURL: URL?
    let pnpmURL: URL?
    let corepackURL: URL?
    let npxURL: URL?
    let version: SemanticVersion
    let architecture: String

    var supportsDSH: Bool {
        (version.major == 22 && version.minor >= 19) || version.major >= 24
    }
}

enum NodeRuntimeStatus: Equatable, Sendable {
    case ready(NodeRuntime)
    case unsupported(NodeRuntime)
    case missingNpm(NodeRuntime)
    case missingNpx(NodeRuntime)
    case notFound
    case failed(String)
}

extension NodeRuntimeStatus {
    var title: String {
        switch self {
        case .ready: "Node.js 已就绪"
        case .unsupported: "Node.js 版本不兼容"
        case .missingNpm: "未找到 npm"
        case .missingNpx: "未找到 npx"
        case .notFound: "未找到 Node.js"
        case .failed: "Node.js 检测失败"
        }
    }

    var detail: String {
        switch self {
        case let .ready(runtime):
            "Node \(runtime.version) · \(runtime.architecture) · \(runtime.nodeURL.path)"
        case let .unsupported(runtime):
            "检测到 Node \(runtime.version)。DSH 目前需要 22.19+（仅 v22）或 v24+。"
        case let .missingNpm(runtime):
            "检测到 Node \(runtime.version)，但未找到配套 npm。请重新安装 Node.js。"
        case let .missingNpx(runtime):
            "检测到 Node \(runtime.version)，但未找到配套 npx。请重新安装 Node.js。"
        case .notFound:
            "请安装兼容的 Node.js，然后返回此处重新检测。"
        case let .failed(message):
            message
        }
    }
}
