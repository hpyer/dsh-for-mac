import AppKit
import Foundation
import Testing
@testable import DshForMac

@MainActor
struct DSHUpdateTests {
    @Test func notificationBridgeHasItsOwnMinimumDSHVersion() {
        let plugin = RecommendedDSHPlugin.taskNotifications
        #expect(plugin.minimumDSHVersion == "0.1.5-rc.3")
        #expect(!plugin.supportsDSHVersion("0.1.5-rc.1"))
        #expect(!plugin.supportsDSHVersion("0.1.5-rc.2"))
        #expect(plugin.supportsDSHVersion("0.1.5-rc.3"))
        #expect(plugin.supportsDSHVersion("0.1.5"))
        #expect(plugin.supportsDSHVersion("0.1.7-rc.1"))
    }

    @Test func minimumDSHVersionHandlesPrereleaseAndStableReleases() {
        #expect(DSHCompatibility.minimumVersion == "0.1.5-rc.1")
        #expect(!DSHCompatibility.supports("0.1.5-alpha.2"))
        #expect(!DSHCompatibility.supports("0.1.5-rc.0"))
        #expect(!DSHCompatibility.supports("0.1.4"))
        #expect(DSHCompatibility.supports("0.1.5-rc.1"))
        #expect(DSHCompatibility.supports("0.1.5-rc.3"))
        #expect(DSHCompatibility.supports("0.1.5"))
        #expect(DSHCompatibility.supports("0.1.6"))
        #expect(DSHCompatibility.supports("0.1.7-rc.1"))
    }

    @Test func incompatibleSelectedDSHIsPreservedAndNeverStarted() async throws {
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
            Issue.record("Expected an incompatible version error")
        } catch let error as DSHRuntimeError {
            if case let .versionBelowMinimum(rejectedVersion) = error {
                #expect(rejectedVersion == version)
            } else {
                Issue.record("Unexpected runtime error: \(error)")
            }
        }
        #expect(FileManager.default.fileExists(atPath: executable.path))
        #expect(fixture.settings.selectedRuntimeVersion == version)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("commands").path))
    }

    @Test func bundleIdentifierMigrationPreservesExistingPreferencesAndRunsOnce() {
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
        #expect(migrated?["dshPort"] as? Int == 5000)
        #expect(migrated?["packageRegistry"] as? String == PackageRegistry.npm.rawValue)

        var changed = migrated ?? [:]
        changed.removeValue(forKey: "packageRegistry")
        defaults.setPersistentDomain(changed, forName: currentDomain)
        AppSettings.migratePreferences(in: defaults, from: legacyDomain, to: currentDomain)
        #expect(defaults.persistentDomain(forName: currentDomain)?["packageRegistry"] == nil)
    }

    @Test func updateTagsPreserveLegacySelectionAndAlwaysIncludeLatest() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        #expect(fixture.settings.updateTags == ["latest"])
        fixture.defaults.set(true, forKey: "dshAdditionalUpdateTagEnabled")
        fixture.defaults.set("beta", forKey: "dshUpdateChannel")
        #expect(fixture.settings.updateTags == ["latest"])
        fixture.settings.lastUpdateCheckDate = Date()
        fixture.settings.updateTags = ["next", "alpha", "alpha", "unknown"]
        #expect(fixture.settings.lastUpdateCheckDate == nil)
        #expect(AppSettings(defaults: fixture.defaults).updateTags == ["latest", "alpha", "next"])
        fixture.settings.updateTags = []
        #expect(AppSettings(defaults: fixture.defaults).updateTags == ["latest"])
    }

    @Test func settingsControlsApplySourcesBeforeCheckingWithoutSaving() throws {
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
        let reminderCheckbox = try #require(buttons.first { $0.title == "后台任务提醒" })
        let testReminder = try #require(buttons.first { $0.title == "发送测试提醒" })
        #expect(!testReminder.isEnabled)
        reminderCheckbox.state = .on
        reminderCheckbox.sendAction(reminderCheckbox.action, to: reminderCheckbox.target)
        #expect(testReminder.isEnabled)
        testReminder.sendAction(testReminder.action, to: testReminder.target)
        #expect(testReminderCount == 1)
        reminderCheckbox.state = .off
        reminderCheckbox.sendAction(reminderCheckbox.action, to: reminderCheckbox.target)
        #expect(!testReminder.isEnabled)
        let latest = try #require(buttons.first { $0.title == "latest" })
        #expect(latest.state == .on)
        #expect(!latest.isEnabled)
        #expect(buttons.first { $0.title == "beta" } == nil)
        for tag in ["alpha", "next"] {
            let checkbox = try #require(buttons.first { $0.title == tag })
            checkbox.state = .on
            checkbox.sendAction(checkbox.action, to: checkbox.target)
        }
        let registry = try #require(views.compactMap { $0 as? NSPopUpButton }.first {
            $0.itemTitles.contains(PackageRegistry.npm.displayName)
        })
        registry.selectItem(withTitle: PackageRegistry.npm.displayName)
        registry.sendAction(registry.action, to: registry.target)
        let appCheck = try #require(buttons.first { $0.title == "检查应用更新" })
        appCheck.sendAction(appCheck.action, to: appCheck.target)
        #expect(appCheckCount == 1)
        #expect(checkedTags.isEmpty)
        let check = try #require(buttons.first { $0.title == "检查 DSH 更新" })
        #expect((check.superview as? NSStackView)?.arrangedSubviews.contains {
            ($0 as? NSTextField)?.stringValue == "正在读取…"
        } == true)
        #expect(!views.compactMap { $0 as? NSTextField }.contains { ["应用", "DSH"].contains($0.stringValue) })
        check.sendAction(check.action, to: check.target)
        #expect(appCheckCount == 1)
        #expect(checkedTags == ["latest", "alpha", "next"])
        #expect(checkedRegistry == .npm)
        #expect(!didApply)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsViewController.preferredWidth, height: 650),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        controller.update(serviceStatus: "运行中", runtimeVersion: "0.1.7-rc.1",
                          installedVersions: ["0.1.7-rc.1"], updateCheckStatus: "DSH 已是最新版本。",
                          canDownloadUpdate: false, isUpdateOperationInProgress: false,
                          recommendedPlugins: [], pluginStatus: "", isPluginOperationInProgress: false)
        let result = try #require(descendants(controller.view).compactMap { $0 as? NSTextField }.first {
            $0.stringValue == "DSH 已是最新版本。"
        })
        #expect(check.superview?.superview === result.superview?.superview)
        window.contentView?.layoutSubtreeIfNeeded()
        let appButtonX = appCheck.convert(.zero, to: controller.view).x
        let dshButtonX = check.convert(.zero, to: controller.view).x
        #expect(abs(appButtonX - dshButtonX) < 1)
        let save = try #require(buttons.first { $0.title == "保存" })
        save.sendAction(save.action, to: save.target)
        #expect(didApply)
        #expect(!didRequestRestart)
        #expect(window.isVisible)
        let close = try #require(buttons.first { $0.title == "关闭" })
        close.sendAction(close.action, to: close.target)
        #expect(!window.isVisible)
    }

    @Test func checksEverySelectedTag() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.settings.updateTags = ["alpha", "beta", "next"]
        _ = try await fixture.manager().checkForUpdates(using: fixture.runtime, reportsProgress: false)
        #expect(try fixture.commands() == ["latest", "alpha", "next"].map {
            "view @deepseek-ai/dsh@\($0) version dist.integrity --json"
        })
    }

    @Test func periodicChecksBecomeDueWhileApplicationRemainsOpen() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let checkedAt = Date(timeIntervalSince1970: 1_000_000)
        for interval in [DSHUpdateCheckInterval.daily, .weekly, .monthly] {
            fixture.settings.updateCheckInterval = interval
            fixture.settings.lastUpdateCheckDate = checkedAt
            let elapsed = try #require(interval.minimumInterval)
            #expect(!fixture.settings.shouldCheckForUpdates(
                now: checkedAt.addingTimeInterval(elapsed - 1), isApplicationLaunch: false
            ))
            #expect(fixture.settings.shouldCheckForUpdates(
                now: checkedAt.addingTimeInterval(elapsed), isApplicationLaunch: false
            ))
            #expect(fixture.settings.shouldCheckForUpdates(
                now: checkedAt.addingTimeInterval(elapsed * 2), isApplicationLaunch: false
            ))
        }
    }

    @Test func launchOnlyAndNeverDoNotRunOnActivationOrTimer() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.settings.updateCheckInterval = .everyLaunch
        #expect(fixture.settings.shouldCheckForUpdates(isApplicationLaunch: true))
        #expect(!fixture.settings.shouldCheckForUpdates(isApplicationLaunch: false))
        fixture.settings.updateCheckInterval = .never
        #expect(!fixture.settings.shouldCheckForUpdates(isApplicationLaunch: true))
        #expect(!fixture.settings.shouldCheckForUpdates(isApplicationLaunch: false))
    }

    @Test func failedAutomaticChecksBackOffAndIntervalChangesTakeEffect() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let now = Date(timeIntervalSince1970: 1_000_000)
        fixture.settings.updateCheckInterval = .daily
        #expect(!fixture.settings.shouldCheckForUpdates(
            now: now, isApplicationLaunch: false, lastAttemptDate: now.addingTimeInterval(-899)
        ))
        #expect(fixture.settings.shouldCheckForUpdates(
            now: now, isApplicationLaunch: false, lastAttemptDate: now.addingTimeInterval(-900)
        ))
        fixture.settings.lastUpdateCheckDate = now.addingTimeInterval(-2 * 86400)
        fixture.settings.updateCheckInterval = .weekly
        #expect(!fixture.settings.shouldCheckForUpdates(now: now, isApplicationLaunch: false))
        fixture.settings.updateCheckInterval = .daily
        #expect(fixture.settings.shouldCheckForUpdates(now: now, isApplicationLaunch: false))
    }

    @Test func downloadConsentStateSurvivesRelaunchAndResetsForAnotherVersion() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.settings.availableUpdateVersion = "1.2.3"
        #expect(!fixture.settings.availableUpdateIsDownloaded)
        let reloaded = AppSettings(defaults: fixture.defaults)
        #expect(reloaded.availableUpdateVersion == "1.2.3")
        #expect(!reloaded.availableUpdateIsDownloaded)
        reloaded.availableUpdateIsDownloaded = true
        #expect(fixture.settings.availableUpdateIsDownloaded)
        reloaded.availableUpdateVersion = "1.2.4"
        #expect(!reloaded.availableUpdateIsDownloaded)
    }

    @Test func checkingOnlyReadsMetadataAndDoesNotRepairOrInstall() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager()
        let directory = fixture.runtimeDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinel = directory.appendingPathComponent("pnpm-lock.yaml")
        try "incomplete installation must remain untouched".write(to: sentinel, atomically: true, encoding: .utf8)
        let result = try await manager.checkForUpdates(using: fixture.runtime, reportsProgress: false)
        #expect(result.version == "1.2.3")
        #expect(!result.isInstalled)
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "incomplete installation must remain untouched")
        #expect(try fixture.commands() == ["view @deepseek-ai/dsh@latest version dist.integrity --json"])
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("package.json").path))
    }

    @Test func explicitDownloadUsesDiscoveredVersionAndCanRetryFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager()
        let result = try await manager.checkForUpdates(using: fixture.runtime, reportsProgress: false)
        #expect(!result.isInstalled)
        // A package-manager failure must leave the version available for an explicit retry.
        try Data().write(to: fixture.root.appendingPathComponent("fail-install"))
        await #expect(throws: DSHRuntimeError.self) {
            try await manager.downloadVersion(result.version, using: fixture.runtime)
        }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("fail-install"))
        try await manager.downloadVersion(result.version, using: fixture.runtime)
        let checkedAgain = try await manager.checkForUpdates(using: fixture.runtime, reportsProgress: false)
        #expect(checkedAgain.isInstalled)
        let commands = try fixture.commands()
        #expect(commands.filter { $0.hasPrefix("view @deepseek-ai/dsh@1.2.3 ") }.count == 2)
        #expect(commands.filter { $0.hasPrefix("install ") }.count == 2)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("DshForMac/runtimes/current").path))
    }

    @Test func restartPrefersSelectedVersionAndExplainsMissingNativeModule() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.settings.selectedRuntimeVersion = "0.1.3-alpha.2"
        let manager = fixture.manager()
        #expect(manager.runtimeVersionForRestart() == "0.1.3-alpha.2")
        #expect(
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
        defaults = try #require(UserDefaults(suiteName: suite))
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
            corepackURL: nil, npxURL: nil, version: try #require(SemanticVersion(string: "22.19.0")),
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
