import Foundation
import XCTest
@testable import DshForMac

final class SemanticVersionTests: XCTestCase {
    func testUpdateCheckIntervalsHaveExpectedCadence() {
        XCTAssertTrue(DSHUpdateCheckInterval.everyLaunch.minimumInterval == 0)
        XCTAssertTrue(DSHUpdateCheckInterval.daily.minimumInterval == TimeInterval(24 * 60 * 60))
        XCTAssertTrue(DSHUpdateCheckInterval.weekly.minimumInterval == TimeInterval(7 * 24 * 60 * 60))
        XCTAssertTrue(DSHUpdateCheckInterval.monthly.minimumInterval == TimeInterval(30 * 24 * 60 * 60))
        XCTAssertTrue(DSHUpdateCheckInterval.never.minimumInterval == nil)
    }

    func testUpdateChannelsOfferPublishedPrereleaseTags() {
        XCTAssertTrue(DSHUpdateChannel.allCases.map(\.additionalTag) == ["alpha", "next"])
    }

    func testFindsCommonPnpmLocationsOutsideTheGuiPath() {
        let home = URL(fileURLWithPath: "/Users/example")
        let candidates = NodeRuntimeDetector.commonPnpmCandidates(homeDirectory: home)

        XCTAssertTrue(candidates.map(\.path).contains("/Users/example/.local/share/pnpm/pnpm"))
        XCTAssertTrue(candidates.map(\.path).contains("/Users/example/Library/pnpm/pnpm"))
        XCTAssertTrue(candidates.map(\.path).contains("/opt/homebrew/bin/pnpm"))
    }

    func testPassesDetectedPnpmToFinderLaunchedDSHProcesses() throws {
        let version = try XCTUnwrap(SemanticVersion(string: "22.19.0"))
        let runtime = NodeRuntime(
            nodeURL: URL(fileURLWithPath: "/opt/homebrew/bin/node"),
            npmURL: URL(fileURLWithPath: "/opt/homebrew/bin/npm"),
            pnpmURL: URL(fileURLWithPath: "/Users/example/.local/share/pnpm/pnpm"),
            corepackURL: URL(fileURLWithPath: "/opt/homebrew/bin/corepack"),
            npxURL: URL(fileURLWithPath: "/opt/homebrew/bin/npx"),
            version: version,
            architecture: "arm64"
        )

        for basePath: String? in [nil, "", "/usr/bin:/bin", "/custom/bin:/usr/local/bin:/custom/bin"] {
            let directories = DSHRuntimeManager.processPath(
                for: runtime, basePath: basePath,
                systemDirectories: ["/usr/bin", "/Library/Apple/usr/bin", "/custom/system/bin"]
            )
                .split(separator: ":").map(String.init)
            XCTAssertTrue(Array(directories.prefix(2)) == ["/opt/homebrew/bin", "/Users/example/.local/share/pnpm"])
            XCTAssertTrue(Set(directories).count == directories.count)
            XCTAssertTrue(directories.contains("/Library/Apple/usr/bin"))
            XCTAssertTrue(directories.contains("/custom/system/bin"))
            for required in ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] {
                XCTAssertTrue(directories.contains(required))
            }
            if basePath?.contains("/custom/bin") == true {
                XCTAssertTrue(directories[2] == "/custom/bin")
                XCTAssertTrue(directories[3] == "/usr/local/bin")
            }
        }
    }

    func testParsesNodeStyleVersion() throws {
        let version = try XCTUnwrap(SemanticVersion(string: "v22.19.0\n"))
        XCTAssertTrue(version == SemanticVersion(string: "22.19.0"))
    }

    func testComparesVersions() throws {
        let older = try XCTUnwrap(SemanticVersion(string: "22.18.0"))
        let newer = try XCTUnwrap(SemanticVersion(string: "22.19.0"))
        XCTAssertTrue(older < newer)
    }

    func testComparesPrereleaseVersionsUsingSemVerPrecedence() throws {
        let beta = try XCTUnwrap(SemanticVersion(string: "1.2.0-beta.2"))
        let rc = try XCTUnwrap(SemanticVersion(string: "1.2.0-rc.1"))
        let stable = try XCTUnwrap(SemanticVersion(string: "1.2.0"))
        let nextPrerelease = try XCTUnwrap(SemanticVersion(string: "1.3.0-alpha.1"))

        XCTAssertTrue(beta < rc)
        XCTAssertTrue(rc < stable)
        XCTAssertTrue(stable < nextPrerelease)
    }

    func testSummarizesIncompatiblePluginExports() {
        let output = """
        Error: failed to import loader entry llm-subscriptions (dsh-plugin-subscriptions): The requested module '@deepseek-ai/dsh-llm' does not provide an export named 'CallId'
        """

        XCTAssertTrue(
            DSHRuntimeManager.conciseRuntimeFailure(from: output)
                == "插件不兼容：dsh-plugin-subscriptions 无法使用 @deepseek-ai/dsh-llm 的 CallId 导出。请选择兼容的已安装版本。"
        )
    }

    func testExtractsAuthenticatedLocalWebURL() {
        let output = "dsh web: http://127.0.0.1:3080/?token=one-time-token\n"

        XCTAssertTrue(
            DSHRuntimeManager.authenticatedWebURL(from: output, port: 3080)?.absoluteString
                == "http://127.0.0.1:3080/?token=one-time-token"
        )
        XCTAssertTrue(DSHRuntimeManager.authenticatedWebURL(from: output, port: 3081) == nil)
    }

    func testAcceptsOnlySupportedDSHNodeRanges() throws {
        let node22 = try XCTUnwrap(SemanticVersion(string: "22.19.0"))
        let node23 = try XCTUnwrap(SemanticVersion(string: "23.0.0"))
        let node24 = try XCTUnwrap(SemanticVersion(string: "24.0.0"))

        XCTAssertTrue(NodeRuntime(nodeURL: URL(fileURLWithPath: "/node"), npmURL: nil, pnpmURL: nil, corepackURL: nil, npxURL: nil, version: node22, architecture: "arm64").supportsDSH)
        XCTAssertTrue(!NodeRuntime(nodeURL: URL(fileURLWithPath: "/node"), npmURL: nil, pnpmURL: nil, corepackURL: nil, npxURL: nil, version: node23, architecture: "arm64").supportsDSH)
        XCTAssertTrue(NodeRuntime(nodeURL: URL(fileURLWithPath: "/node"), npmURL: nil, pnpmURL: nil, corepackURL: nil, npxURL: nil, version: node24, architecture: "arm64").supportsDSH)
    }
}
