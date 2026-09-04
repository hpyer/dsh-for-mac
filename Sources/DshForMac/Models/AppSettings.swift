import Foundation

enum AppMetadata {
    static let version = "0.3.2"
}

enum PackageRegistry: String, CaseIterable, Sendable {
    case tencent
    case npmmirror
    case yarn
    case npm

    var displayName: String {
        switch self {
        case .tencent: "腾讯云镜像（默认）"
        case .npmmirror: "npmmirror"
        case .yarn: "Yarn 镜像"
        case .npm: "npm 官方"
        }
    }

    var url: String {
        switch self {
        case .tencent: "https://mirrors.cloud.tencent.com/npm/"
        case .npmmirror: "https://registry.npmmirror.com/"
        case .yarn: "https://registry.yarnpkg.com/"
        case .npm: "https://registry.npmjs.org/"
        }
    }
}

enum DSHUpdateCheckInterval: String, CaseIterable, Sendable {
    case everyLaunch
    case daily
    case weekly
    case monthly
    case never

    var displayName: String {
        switch self {
        case .everyLaunch: "每次启动"
        case .daily: "每天"
        case .weekly: "每周"
        case .monthly: "每月"
        case .never: "不检查"
        }
    }

    var minimumInterval: TimeInterval? {
        switch self {
        case .everyLaunch: 0
        case .daily: 24 * 60 * 60
        case .weekly: 7 * 24 * 60 * 60
        case .monthly: 30 * 24 * 60 * 60
        case .never: nil
        }
    }
}

enum DSHUpdateChannel: String, CaseIterable, Sendable {
    case alpha
    case beta
    case next

    var displayName: String {
        switch self {
        case .alpha: "alpha"
        case .beta: "beta"
        case .next: "next"
        }
    }

    var additionalTag: String { rawValue }
}

@MainActor
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let registry = "packageRegistry"
        static let selectedRuntimeVersion = "selectedRuntimeVersion"
        static let port = "dshPort"
        static let updateCheckInterval = "dshUpdateCheckInterval"
        static let additionalUpdateTagEnabled = "dshAdditionalUpdateTagEnabled"
        static let updateChannel = "dshUpdateChannel"
        static let lastUpdateCheckDate = "dshLastUpdateCheckDate"
        static let availableUpdateVersion = "dshAvailableUpdateVersion"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var registry: PackageRegistry {
        get {
            guard let value = defaults.string(forKey: Key.registry),
                  let registry = PackageRegistry(rawValue: value)
            else {
                return .tencent
            }
            return registry
        }
        set {
            guard registry != newValue else { return }
            defaults.set(newValue.rawValue, forKey: Key.registry)
            lastUpdateCheckDate = nil
        }
    }

    var selectedRuntimeVersion: String? {
        get { defaults.string(forKey: Key.selectedRuntimeVersion) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.selectedRuntimeVersion)
            } else {
                defaults.removeObject(forKey: Key.selectedRuntimeVersion)
            }
        }
    }

    var port: Int {
        get {
            let value = defaults.object(forKey: Key.port) as? Int ?? 3080
            return (1...65_535).contains(value) ? value : 3080
        }
        set {
            defaults.set(newValue, forKey: Key.port)
        }
    }

    var updateCheckInterval: DSHUpdateCheckInterval {
        get {
            guard let value = defaults.string(forKey: Key.updateCheckInterval),
                  let interval = DSHUpdateCheckInterval(rawValue: value)
            else {
                return .everyLaunch
            }
            return interval
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.updateCheckInterval)
        }
    }

    var updateChannel: DSHUpdateChannel {
        get {
            guard let value = defaults.string(forKey: Key.updateChannel),
                  let channel = DSHUpdateChannel(rawValue: value)
            else {
                return .alpha
            }
            return channel
        }
        set {
            guard updateChannel != newValue else { return }
            defaults.set(newValue.rawValue, forKey: Key.updateChannel)
            lastUpdateCheckDate = nil
        }
    }

    var additionalUpdateTagEnabled: Bool {
        get { defaults.bool(forKey: Key.additionalUpdateTagEnabled) }
        set {
            guard additionalUpdateTagEnabled != newValue else { return }
            defaults.set(newValue, forKey: Key.additionalUpdateTagEnabled)
            lastUpdateCheckDate = nil
        }
    }

    var lastUpdateCheckDate: Date? {
        get { defaults.object(forKey: Key.lastUpdateCheckDate) as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.lastUpdateCheckDate)
            } else {
                defaults.removeObject(forKey: Key.lastUpdateCheckDate)
            }
        }
    }

    var availableUpdateVersion: String? {
        get { defaults.string(forKey: Key.availableUpdateVersion) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.availableUpdateVersion)
            } else {
                defaults.removeObject(forKey: Key.availableUpdateVersion)
            }
        }
    }

    func shouldCheckForUpdates(now: Date = Date()) -> Bool {
        guard let minimumInterval = updateCheckInterval.minimumInterval else { return false }
        guard let lastUpdateCheckDate else { return true }
        return now.timeIntervalSince(lastUpdateCheckDate) >= minimumInterval
    }
}
