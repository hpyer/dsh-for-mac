import AppKit
import Foundation
import XCTest
@testable import DshForMac

@MainActor
final class DSHUpdateTests: XCTestCase {
    func testNotificationBridgeHasItsOwnMinimumDSHVersion() {
        let plugin = RecommendedDSHPlugin.taskNotifications
        XCTAssertTrue(plugin.minimumDSHVersion == "0.1.5-rc.3")
        XCTAssertTrue(!plugin.supportsDSHVersion("0.1.5-rc.1"))
        XCTAssertTrue(!plugin.supportsDSHVersion("0.1.5-rc.2"))
        XCTAssertTrue(plugin.supportsDSHVersion("0.1.5-rc.3"))
        XCTAssertTrue(plugin.supportsDSHVersion("0.1.5"))
        XCTAssertTrue(plugin.supportsDSHVersion("0.1.7-rc.1"))
    }

    func testMinimumDSHVersionHandlesPrereleaseAndStableReleases() {
        XCTAssertTrue(DSHCompatibility.minimumVersion == "0.1.5-rc.1")
        XCTAssertTrue(!DSHCompatibility.supports("0.1.5-alpha.2"))
        XCTAssertTrue(!DSHCompatibility.supports("0.1.5-rc.0"))
        XCTAssertTrue(!DSHCompatibility.supports("0.1.4"))
        XCTAssertTrue(DSHCompatibility.supports("0.1.5-rc.1"))
        XCTAssertTrue(DSHCompatibility.supports("0.1.5-rc.3"))
        XCTAssertTrue(DSHCompatibility.supports("0.1.5"))
        XCTAssertTrue(DSHCompatibility.supports("0.1.6"))
        XCTAssertTrue(DSHCompatibility.supports("0.1.7-rc.1"))
    }

    func testIncompatibleSelectedDSHIsPreservedAndNeverStarted() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let version = "0.1.5-rc.0"
        fixture.settings.selectedRuntimeVersion = version
        let directory = fixture.root.appendingPathComponent("DshForMac/runtimes/versions/\(version)")
        let executable = directory.appendingPathComponent("node_modules/.bin/dsh")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        do {
            _ = try await fixture.manager().start(using: fixture.runtime)
            XCTFail("Expected an incompatible version error")
        } catch let error as DSHRuntimeError {
            if case let .versionBelowMinimum(rejectedVersion) = error {
                XCTAssertTrue(rejectedVersion == version)
            } else {
                XCTFail("Unexpected runtime error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: executable.path))
        XCTAssertTrue(fixture.settings.selectedRuntimeVersion == version)
        XCTAssertTrue(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("commands").path))
    }

    func testBundleIdentifierMigrationPreservesExistingPreferencesAndRunsOnce() {
        let legacyDomain = "DshForMacTests.legacy.\(UUID().uuidString)"
        let currentDomain = "DshForMacTests.current.\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        defer {
            defaults.removePersistentDomain(forName: legacyDomain)
            defaults.removePersistentDomain(forName: currentDomain)
        }

        defaults.setPersistentDomain(
            ["dshPort": 4000, "packageRegistry": PackageRegistry.npm.rawValue],
            forName: legacyDomain
        )
        defaults.setPersistentDomain(["dshPort": 5000], forName: currentDomain)
        AppSettings.migratePreferences(in: defaults, from: legacyDomain, to: currentDomain)

        let migrated = defaults.persistentDomain(forName: currentDomain)
        XCTAssertTrue(migrated?["dshPort"] as? Int == 5000)
        XCTAssertTrue(migrated?["packageRegistry"] as? String == PackageRegistry.npm.rawValue)

        var changed = migrated ?? [:]
        changed.removeValue(forKey: "packageRegistry")
        defaults.setPersistentDomain(changed, forName: currentDomain)
        AppSettings.migratePreferences(in: defaults, from: legacyDomain, to: currentDomain)
        XCTAssertTrue(defaults.persistentDomain(forName: currentDomain)?["packageRegistry"] == nil)
    }

    func testUpdateTagsPreserveLegacySelectionAndAlwaysIncludeLatest() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.settings.updateTags == ["latest"])
        fixture.defaults.set(true, forKey: "dshAdditionalUpdateTagEnabled")
        fixture.defaults.set("beta", forKey: "dshUpdateChannel")
        XCTAssertTrue(fixture.settings.updateTags == ["latest"])
        fixture.settings.lastUpdateCheckDate = Date()
        fixture.settings.updateTags = ["next", "alpha", "alpha", "unknown"]
        XCTAssertTrue(fixture.settings.lastUpdateCheckDate == nil)
        XCTAssertTrue(AppSettings(defaults: fixture.defaults).updateTags == ["latest", "alpha", "next"])
        fixture.settings.updateTags = []
        XCTAssertTrue(AppSettings(defaults: fixture.defaults).updateTags == ["latest"])
    }

    func testSettingsControlsApplySourcesBeforeCheckingWithoutSaving() throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var checkedTags: [String] = []
        var checkedRegistry: PackageRegistry?
        var appCheckCount = 0
        var testReminderCount = 0
        var didApply = false
        var didRequestRestart = false
        let controller = SettingsViewController(
            settings: fixture.settings,
            onApply: { _, restartRequired, _ in
                didApply = true
                didRequestRestart = restartRequired
            },
            onTestTaskReminder: { testReminderCount += 1 },
            onCheckUpdates: {
                checkedTags = fixture.settings.updateTags
                checkedRegistry = fixture.settings.registry
            },
            onCheckAppUpdates: { appCheckCount += 1 },
            onDownloadUpdate: {}, onOpenVersionsDirectory: {}
        )
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let views = descendants(controller.view)
        let buttons = views.compactMap { $0 as? NSButton }
        let reminderCheckbox = try XCTUnwrap(buttons.first { $0.title == "后台任务提醒" })
        let testReminder = try XCTUnwrap(buttons.first { $0.title == "发送测试提醒" })
        XCTAssertTrue(!testReminder.isEnabled)
        reminderCheckbox.state = .on
        reminderCheckbox.sendAction(reminderCheckbox.action, to: reminderCheckbox.target)
        XCTAssertTrue(testReminder.isEnabled)
        testReminder.sendAction(testReminder.action, to: testReminder.target)
        XCTAssertTrue(testReminderCount == 1)
        reminderCheckbox.state = .off
        reminderCheckbox.sendAction(reminderCheckbox.action, to: reminderCheckbox.target)
        XCTAssertTrue(!testReminder.isEnabled)
        let latest = try XCTUnwrap(buttons.first { $0.title == "latest" })
        XCTAssertTrue(latest.state == .on)
        XCTAssertTrue(!latest.isEnabled)
        XCTAssertTrue(buttons.first { $0.title == "beta" } == nil)
        for tag in ["alpha", "next"] {
            let checkbox = try XCTUnwrap(buttons.first { $0.title == tag })
            checkbox.state = .on
            checkbox.sendAction(checkbox.action, to: checkbox.target)
        }
        let registry = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first {
            $0.itemTitles.contains(PackageRegistry.npm.displayName)
        })
        registry.selectItem(withTitle: PackageRegistry.npm.displayName)
        registry.sendAction(registry.action, to: registry.target)
        let appCheck = try XCTUnwrap(buttons.first { $0.title == "检查应用更新" })
        appCheck.sendAction(appCheck.action, to: appCheck.target)
        XCTAssertTrue(appCheckCount == 1)
        XCTAssertTrue(checkedTags.isEmpty)
        let check = try XCTUnwrap(buttons.first { $0.title == "检查 DSH 更新" })
        XCTAssertTrue((check.superview as? NSStackView)?.arrangedSubviews.contains {
            ($0 as? NSTextField)?.stringValue == "正在读取…"
        } == true)
        XCTAssertTrue(!views.compactMap { $0 as? NSTextField }.contains { ["应用", "DSH"].contains($0.stringValue) })
        check.sendAction(check.action, to: check.target)
        XCTAssertTrue(appCheckCount == 1)
        XCTAssertTrue(checkedTags == ["latest", "alpha", "next"])
        XCTAssertTrue(checkedRegistry == .npm)
        XCTAssertTrue(!didApply)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsViewController.preferredWidth, height: 650),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        controller.update(serviceStatus: "运行中", runtimeVersion: "0.1.7-rc.1",
                          installedVersions: ["0.1.7-rc.1"], updateCheckStatus: "DSH 已是最新版本。",
                          canDownloadUpdate: false, isUpdateOperationInProgress: false,
                          recommendedPlugins: [], pluginStatus: "", isPluginOperationInProgress: false)
        let result = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSTextField }.first {
            $0.stringValue == "DSH 已是最新版本。"
        })
        XCTAssertTrue(check.superview?.superview === result.superview?.superview)
        window.contentView?.layoutSubtreeIfNeeded()
        let appButtonX = appCheck.convert(.zero, to: controller.view).x
        let dshButtonX = check.convert(.zero, to: controller.view).x
        XCTAssertTrue(abs(appButtonX - dshButtonX) < 1)
        let save = try XCTUnwrap(buttons.first { $0.title == "保存" })
        save.sendAction(save.action, to: save.target)
        XCTAssertTrue(didApply)
        XCTAssertTrue(!didRequestRestart)
        XCTAssertTrue(window.isVisible)
        let close = try XCTUnwrap(buttons.first { $0.title == "关闭" })
        close.sendAction(close.action, to: close.target)
        XCTAssertTrue(!window.isVisible)
    }

    func testChecksEverySelectedTag() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.settings.updateTags = ["alpha", "beta", "next"]
        _ = try await fixture.manager().checkForUpdates(using: fixture.runtime, reportsProgress: false)
        XCTAssertTrue(try fixture.commands() == ["latest", "alpha", "next"].map {
            "view @deepseek-ai/dsh@\($0) version dist.integrity --json"
        })
    }

    func testPeriodicChecksBecomeDueWhileApplicationRemainsOpen() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let checkedAt = Date(timeIntervalSince1970: 1_000_000)
        for interval in [DSHUpdateCheckInterval.daily, .weekly, .monthly] {
            fixture.settings.updateCheckInterval = interval
            fixture.settings.lastUpdateCheckDate = checkedAt
            let elapsed = try XCTUnwrap(interval.minimumInterval)
            XCTAssertTrue(!fixture.settings.shouldCheckForUpdates(
                now: checkedAt.addingTimeInterval(elapsed - 1), isApplicationLaunch: false
            ))
            XCTAssertTrue(fixture.settings.shouldCheckForUpdates(
                now: checkedAt.addingTimeInterval(elapsed), isApplicationLaunch: false
            ))
            XCTAssertTrue(fixture.settings.shouldCheckForUpdates(
                now: checkedAt.addingTimeInterval(elapsed * 2), isApplicationLaunch: false
            ))
        }
    }

    func testLaunchOnlyAndNeverDoNotRunOnActivationOrTimer() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.settings.updateCheckInterval = .everyLaunch
        XCTAssertTrue(fixture.settings.shouldCheckForUpdates(isApplicationLaunch: true))
        XCTAssertTrue(!fixture.settings.shouldCheckForUpdates(isApplicationLaunch: false))
        fixture.settings.updateCheckInterval = .never
        XCTAssertTrue(!fixture.settings.shouldCheckForUpdates(isApplicationLaunch: true))
        XCTAssertTrue(!fixture.settings.shouldCheckForUpdates(isApplicationLaunch: false))
    }

    func testFailedAutomaticChecksBackOffAndIntervalChangesTakeEffect() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let now = Date(timeIntervalSince1970: 1_000_000)
        fixture.settings.updateCheckInterval = .daily
        XCTAssertTrue(!fixture.settings.shouldCheckForUpdates(
            now: now, isApplicationLaunch: false, lastAttemptDate: now.addingTimeInterval(-899)
        ))
        XCTAssertTrue(fixture.settings.shouldCheckForUpdates(
            now: now, isApplicationLaunch: false, lastAttemptDate: now.addingTimeInterval(-900)
        ))
        fixture.settings.lastUpdateCheckDate = now.addingTimeInterval(-2 * 86400)
        fixture.settings.updateCheckInterval = .weekly
        XCTAssertTrue(!fixture.settings.shouldCheckForUpdates(now: now, isApplicationLaunch: false))
        fixture.settings.updateCheckInterval = .daily
        XCTAssertTrue(fixture.settings.shouldCheckForUpdates(now: now, isApplicationLaunch: false))
    }

    func testDownloadConsentStateSurvivesRelaunchAndResetsForAnotherVersion() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.settings.availableUpdateVersion = "1.2.3"
        XCTAssertTrue(!fixture.settings.availableUpdateIsDownloaded)
        let reloaded = AppSettings(defaults: fixture.defaults)
        XCTAssertTrue(reloaded.availableUpdateVersion == "1.2.3")
        XCTAssertTrue(!reloaded.availableUpdateIsDownloaded)
        reloaded.availableUpdateIsDownloaded = true
        XCTAssertTrue(fixture.settings.availableUpdateIsDownloaded)
        reloaded.availableUpdateVersion = "1.2.4"
        XCTAssertTrue(!reloaded.availableUpdateIsDownloaded)
    }

    func testCheckingOnlyReadsMetadataAndDoesNotRepairOrInstall() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager()
        let directory = fixture.runtimeDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinel = directory.appendingPathComponent("pnpm-lock.yaml")
        try "incomplete installation must remain untouched".write(to: sentinel, atomically: true, encoding: .utf8)
        let result = try await manager.checkForUpdates(using: fixture.runtime, reportsProgress: false)
        XCTAssertTrue(result.version == "1.2.3")
        XCTAssertTrue(!result.isInstalled)
        XCTAssertTrue(try String(contentsOf: sentinel, encoding: .utf8) == "incomplete installation must remain untouched")
        XCTAssertTrue(try fixture.commands() == ["view @deepseek-ai/dsh@latest version dist.integrity --json"])
        XCTAssertTrue(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("package.json").path))
    }

    func testExplicitDownloadUsesDiscoveredVersionAndCanRetryFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager()
        let result = try await manager.checkForUpdates(using: fixture.runtime, reportsProgress: false)
        XCTAssertTrue(!result.isInstalled)
        // A package-manager failure must leave the version available for an explicit retry.
        try Data().write(to: fixture.root.appendingPathComponent("fail-install"))
        do {
            try await manager.downloadVersion(result.version, using: fixture.runtime)
            XCTFail("Expected a DSH runtime error")
        } catch is DSHRuntimeError {
            // The failed installation remains available for an explicit retry.
        } catch {
            XCTFail("Unexpected download error: \(error)")
        }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("fail-install"))
        try await manager.downloadVersion(result.version, using: fixture.runtime)
        let checkedAgain = try await manager.checkForUpdates(using: fixture.runtime, reportsProgress: false)
        XCTAssertTrue(checkedAgain.isInstalled)
        let commands = try fixture.commands()
        XCTAssertTrue(commands.filter { $0.hasPrefix("view @deepseek-ai/dsh@1.2.3 ") }.count == 2)
        XCTAssertTrue(commands.filter { $0.hasPrefix("install ") }.count == 2)
        XCTAssertTrue(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("DshForMac/runtimes/current").path))
    }

    func testRestartPrefersSelectedVersionAndExplainsMissingNativeModule() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.settings.selectedRuntimeVersion = "0.1.3-alpha.2"
        let manager = fixture.manager()
        XCTAssertTrue(manager.runtimeVersionForRestart() == "0.1.3-alpha.2")
        XCTAssertTrue(
            DSHRuntimeManager.conciseMissingModuleFailure(
                from: "Error: Cannot find module './build/Release/fs_ext.node'"
            ) == "DSH 启动依赖缺失：找不到模块 ./build/Release/fs_ext.node。请重新下载该 DSH 版本以重建原生依赖。"
        )
    }
}

@MainActor
private final class Fixture {
    let root: URL
    let suiteName: String
    let defaults: UserDefaults
    let settings: AppSettings
    let runtime: NodeRuntime
    var runtimeDirectory: URL { root.appendingPathComponent("DshForMac/runtimes/versions/1.2.3") }

    init() throws {
        let suite = "DSHUpdateTests.\(UUID().uuidString)"
        suiteName = suite
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        settings = AppSettings(defaults: defaults)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let npm = root.appendingPathComponent("npm")
        // Test double for npm: all commands are local, logged, and deterministic.
        let script = #"""
        #!/bin/sh
        fixture_dir=$(/usr/bin/dirname "$0")
        printf '%s\n' "$*" >> "$fixture_dir/commands"
        case "$1" in
          view)
            printf '%s\n' '{"version":"1.2.3","dist.integrity":"sha512-test"}'
            ;;
          install)
            if [ -f "$fixture_dir/fail-install" ]; then exit 1; fi
            /bin/mkdir -p node_modules/.bin
            printf '#!/bin/sh\nexit 0\n' > node_modules/.bin/dsh
            /bin/chmod +x node_modules/.bin/dsh
            printf '%s\n' '{"packages":{"node_modules/@deepseek-ai/dsh":{"integrity":"sha512-test"}}}' > package-lock.json
            ;;
          rebuild)
            ;;
          *) exit 1 ;;
        esac
        """#
        try script.write(to: npm, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: npm.path)
        runtime = NodeRuntime(
            nodeURL: root.appendingPathComponent("node"), npmURL: npm, pnpmURL: nil,
            corepackURL: nil, npxURL: nil, version: try XCTUnwrap(SemanticVersion(string: "22.19.0")),
            architecture: "arm64"
        )
    }

    func manager() -> DSHRuntimeManager {
        DSHRuntimeManager(settings: settings, supportDirectory: root, statusHandler: { _ in })
    }

    func commands() throws -> [String] {
        try String(contentsOf: root.appendingPathComponent("commands"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}
