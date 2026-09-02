import Foundation
import Testing
@testable import DshForMac

struct SemanticVersionTests {
    @Test func updateCheckIntervalsHaveExpectedCadence() {
        #expect(DSHUpdateCheckInterval.everyLaunch.minimumInterval == 0)
        #expect(DSHUpdateCheckInterval.daily.minimumInterval == TimeInterval(24 * 60 * 60))
        #expect(DSHUpdateCheckInterval.weekly.minimumInterval == TimeInterval(7 * 24 * 60 * 60))
        #expect(DSHUpdateCheckInterval.monthly.minimumInterval == TimeInterval(30 * 24 * 60 * 60))
        #expect(DSHUpdateCheckInterval.never.minimumInterval == nil)
    }

    @Test func updateChannelsOfferCommonPrereleaseTags() {
        #expect(DSHUpdateChannel.alpha.additionalTag == "alpha")
        #expect(DSHUpdateChannel.beta.additionalTag == "beta")
        #expect(DSHUpdateChannel.next.additionalTag == "next")
    }

    @Test func findsCommonPnpmLocationsOutsideTheGuiPath() {
        let home = URL(fileURLWithPath: "/Users/example")
        let candidates = NodeRuntimeDetector.commonPnpmCandidates(homeDirectory: home)

        #expect(candidates.map(\.path).contains("/Users/example/.local/share/pnpm/pnpm"))
        #expect(candidates.map(\.path).contains("/Users/example/Library/pnpm/pnpm"))
        #expect(candidates.map(\.path).contains("/opt/homebrew/bin/pnpm"))
    }

    @Test func parsesNodeStyleVersion() throws {
        let version = try #require(SemanticVersion(string: "v22.19.0\n"))
        #expect(version == SemanticVersion(string: "22.19.0"))
    }

    @Test func comparesVersions() throws {
        let older = try #require(SemanticVersion(string: "22.18.0"))
        let newer = try #require(SemanticVersion(string: "22.19.0"))
        #expect(older < newer)
    }

    @Test func comparesPrereleaseVersionsUsingSemVerPrecedence() throws {
        let beta = try #require(SemanticVersion(string: "1.2.0-beta.2"))
        let rc = try #require(SemanticVersion(string: "1.2.0-rc.1"))
        let stable = try #require(SemanticVersion(string: "1.2.0"))
        let nextPrerelease = try #require(SemanticVersion(string: "1.3.0-alpha.1"))

        #expect(beta < rc)
        #expect(rc < stable)
        #expect(stable < nextPrerelease)
    }

    @Test func summarizesIncompatiblePluginExports() {
        let output = """
        Error: failed to import loader entry llm-subscriptions (dsh-plugin-subscriptions): The requested module '@deepseek-ai/dsh-llm' does not provide an export named 'CallId'
        """

        #expect(
            DSHRuntimeManager.conciseRuntimeFailure(from: output)
                == "插件不兼容：dsh-plugin-subscriptions 无法使用 @deepseek-ai/dsh-llm 的 CallId 导出。请选择兼容的已安装版本。"
        )
    }

    @Test func extractsAuthenticatedLocalWebURL() {
        let output = "dsh web: http://127.0.0.1:3080/?token=one-time-token\n"

        #expect(
            DSHRuntimeManager.authenticatedWebURL(from: output, port: 3080)?.absoluteString
                == "http://127.0.0.1:3080/?token=one-time-token"
        )
        #expect(DSHRuntimeManager.authenticatedWebURL(from: output, port: 3081) == nil)
    }

    @Test func acceptsOnlySupportedDSHNodeRanges() throws {
        let node22 = try #require(SemanticVersion(string: "22.19.0"))
        let node23 = try #require(SemanticVersion(string: "23.0.0"))
        let node24 = try #require(SemanticVersion(string: "24.0.0"))

        #expect(NodeRuntime(nodeURL: URL(fileURLWithPath: "/node"), npmURL: nil, pnpmURL: nil, corepackURL: nil, npxURL: nil, version: node22, architecture: "arm64").supportsDSH)
        #expect(!NodeRuntime(nodeURL: URL(fileURLWithPath: "/node"), npmURL: nil, pnpmURL: nil, corepackURL: nil, npxURL: nil, version: node23, architecture: "arm64").supportsDSH)
        #expect(NodeRuntime(nodeURL: URL(fileURLWithPath: "/node"), npmURL: nil, pnpmURL: nil, corepackURL: nil, npxURL: nil, version: node24, architecture: "arm64").supportsDSH)
    }
}
