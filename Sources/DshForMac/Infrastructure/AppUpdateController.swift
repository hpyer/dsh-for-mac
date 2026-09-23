import AppKit
import Sparkle

@MainActor
final class AppUpdateController: NSObject, SPUUpdaterDelegate {
    static let releasesURL = URL(string: "https://github.com/hpyer/dsh-for-mac/releases")!

    var onStatusChanged: ((String) -> Void)?
    var onFailure: ((String, Bool) -> Void)?
    var onAvailabilityChanged: (() -> Void)?

    private var updaterController: SPUStandardUpdaterController?
    private var unavailableReason: String?
    private var userInitiatedCheck = false
    private var foundUpdate = false

    var canCheckForUpdates: Bool {
        updaterController?.updater.canCheckForUpdates ?? true
    }

    func start() {
        // `swift run` has no application bundle to replace. The packaged app does.
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app" else {
            unavailableReason = "当前运行的不是已安装的 DshForMac.app。"
            return
        }
        let isReadOnly = (try? appURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
        if isReadOnly || appURL.path.contains("/AppTranslocation/") {
            unavailableReason = "请先将 DshForMac.app 从 DMG 移至“应用程序”，再使用应用内更新。"
            onStatusChanged?(unavailableReason ?? "")
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        updaterController = controller
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard let updaterController else {
            onFailure?(unavailableReason ?? "请从发布页面安装 DshForMac.app 后检查更新。", false)
            return
        }
        guard updaterController.updater.canCheckForUpdates else { return }
        userInitiatedCheck = true
        foundUpdate = false
        onStatusChanged?("正在检查 DshForMac 更新…")
        updaterController.checkForUpdates(nil)
        onAvailabilityChanged?()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        foundUpdate = true
        onStatusChanged?("发现 DshForMac \(item.displayVersionString) 更新。")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        if userInitiatedCheck {
            onStatusChanged?("DshForMac 已是适用于此 Mac 的最新版本。")
        }
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        switch choice {
        case .skip:
            onStatusChanged?("已忽略 DshForMac \(item.displayVersionString)，手动检查仍可找到此版本。")
        case .dismiss:
            onStatusChanged?("已稍后提醒 DshForMac \(item.displayVersionString) 更新。")
        case .install:
            onStatusChanged?("正在下载并安装 DshForMac \(item.displayVersionString)…")
        @unknown default:
            break
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        DispatchQueue.main.async { [weak self] in self?.onAvailabilityChanged?() }
        defer {
            userInitiatedCheck = false
            foundUpdate = false
        }
        guard let error else { return }
        let nsError = error as NSError
        // Sparkle reports "no update" and user-cancelled authorization as errors.
        if nsError.domain == SUSparkleErrorDomain && [1001, 4007, 4008].contains(nsError.code) {
            return
        }
        let reason = nsError.localizedDescription
        onStatusChanged?("DshForMac 更新失败：\(reason)")
        if userInitiatedCheck || foundUpdate {
            let verificationFailed = nsError.domain == SUSparkleErrorDomain && [3001, 3002].contains(nsError.code)
            onFailure?(reason, !verificationFailed)
        }
    }
}
