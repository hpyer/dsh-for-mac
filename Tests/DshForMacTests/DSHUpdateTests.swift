import Foundation
import Testing
@testable import DshForMac

@MainActor
struct DSHUpdateTests {
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
