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

    @Test func acceptsOnlySupportedDSHNodeRanges() throws {
        let node22 = try #require(SemanticVersion(string: "22.19.0"))
        let node23 = try #require(SemanticVersion(string: "23.0.0"))
        let node24 = try #require(SemanticVersion(string: "24.0.0"))

        #expect(NodeRuntime(nodeURL: URL(fileURLWithPath: "/node"), npmURL: nil, pnpmURL: nil, corepackURL: nil, npxURL: nil, version: node22, architecture: "arm64").supportsDSH)
        #expect(!NodeRuntime(nodeURL: URL(fileURLWithPath: "/node"), npmURL: nil, pnpmURL: nil, corepackURL: nil, npxURL: nil, version: node23, architecture: "arm64").supportsDSH)
        #expect(NodeRuntime(nodeURL: URL(fileURLWithPath: "/node"), npmURL: nil, pnpmURL: nil, corepackURL: nil, npxURL: nil, version: node24, architecture: "arm64").supportsDSH)
    }
}
