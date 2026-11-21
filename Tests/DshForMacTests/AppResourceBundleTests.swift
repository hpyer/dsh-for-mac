import Foundation
import XCTest
@testable import DshForMac

final class AppResourceBundleTests: XCTestCase {
    func testFindsResourcesInTheTestBuild() throws {
        let script = try XCTUnwrap(AppResourceBundle.url(
            forResource: "anchor-positioning", withExtension: "js"
        ))
        XCTAssertTrue(script.path.hasSuffix("DshForMac_DshForMac.bundle/anchor-positioning.js"))
        XCTAssertFalse(try String(contentsOf: script, encoding: .utf8).isEmpty)

        XCTAssertNotNil(AppResourceBundle.url(
            forResource: "session-repair", withExtension: "mjs"
        ))
    }

    func testResolvesResourcesInAPackagedApplication() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("DshForMac.app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        let bundle = resources.appendingPathComponent("DshForMac_DshForMac.bundle", isDirectory: true)
        try writeResource(named: "anchor-positioning.js", into: bundle)

        let resolved = try XCTUnwrap(AppResourceBundle.url(
            forResource: "anchor-positioning",
            withExtension: "js",
            resourceURL: resources,
            bundleURL: app
        ))
        XCTAssertEqual(resolved.standardizedFileURL,
                       bundle.appendingPathComponent("anchor-positioning.js").standardizedFileURL)
    }

    func testResolvesResourcesBesideTheExecutable() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let build = root.appendingPathComponent(".build/release", isDirectory: true)
        let bundle = build.appendingPathComponent("DshForMac_DshForMac.bundle", isDirectory: true)
        try writeResource(named: "session-repair.mjs", into: bundle)

        let resolved = try XCTUnwrap(AppResourceBundle.url(
            forResource: "session-repair",
            withExtension: "mjs",
            resourceURL: nil,
            bundleURL: build
        ))
        XCTAssertEqual(resolved.standardizedFileURL,
                       bundle.appendingPathComponent("session-repair.mjs").standardizedFileURL)
    }

    func testResolvesResourcesFromAnXCTestBundleParent() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let testBundle = root.appendingPathComponent("DshForMacPackageTests.xctest", isDirectory: true)
        let bundle = root.appendingPathComponent("DshForMac_DshForMac.bundle", isDirectory: true)
        try writeResource(named: "anchor-positioning.js", into: bundle)

        let resolved = try XCTUnwrap(AppResourceBundle.url(
            forResource: "anchor-positioning",
            withExtension: "js",
            resourceURL: testBundle.appendingPathComponent("Contents/Resources", isDirectory: true),
            bundleURL: testBundle
        ))
        XCTAssertEqual(resolved.standardizedFileURL,
                       bundle.appendingPathComponent("anchor-positioning.js").standardizedFileURL)
    }

    func testMissingResourcesReturnNilInsteadOfTrapping() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(AppResourceBundle.url(
            forResource: "missing",
            withExtension: "js",
            resourceURL: root.appendingPathComponent("Contents/Resources", isDirectory: true),
            bundleURL: root.appendingPathComponent("Missing.app", isDirectory: true)
        ))
        XCTAssertNil(AppResourceBundle.string(forResource: "missing", withExtension: "js"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppResourceBundleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeResource(named name: String, into bundle: URL) throws {
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: bundle.appendingPathComponent(name))
    }
}
