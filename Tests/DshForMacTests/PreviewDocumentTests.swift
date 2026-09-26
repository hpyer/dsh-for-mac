import Foundation
import XCTest
@testable import DshForMac

final class PreviewDocumentTests: XCTestCase {
    func testInterceptsSupportedProducedFileOpenRPCs() {
        XCTAssertTrue(ProducedFilePreviewBridge.interceptsOpenPathRequest(
            at: URL(string: "http://127.0.0.1:3080/api/session/openWorkspacePath")!
        ))
        XCTAssertTrue(ProducedFilePreviewBridge.interceptsOpenPathRequest(
            at: URL(string: "http://127.0.0.1:3080/api/host/openPath")!
        ))
        XCTAssertTrue(!ProducedFilePreviewBridge.interceptsOpenPathRequest(
            at: URL(string: "http://127.0.0.1:3080/api/session/canOpenWorkspacePath")!
        ))
    }

    func testDetectsPreviewableFileExtensions() {
        XCTAssertTrue(PreviewContentKind.detect(url: URL(fileURLWithPath: "/tmp/result.ts")) == .text)
        XCTAssertTrue(PreviewContentKind.detect(url: URL(fileURLWithPath: "/tmp/report.md")) == .markdown)
        XCTAssertTrue(PreviewContentKind.detect(url: URL(fileURLWithPath: "/tmp/schema.sql")) == .text)
        XCTAssertTrue(PreviewContentKind.detect(url: URL(fileURLWithPath: "/tmp/Example.java")) == .text)
        XCTAssertTrue(PreviewContentKind.detect(url: URL(fileURLWithPath: "/tmp/Component.vue")) == .text)
        XCTAssertTrue(PreviewContentKind.detect(url: URL(fileURLWithPath: "/tmp/chart.svg")) == .svg)
        XCTAssertTrue(PreviewContentKind.detect(url: URL(fileURLWithPath: "/tmp/screenshot.png")) == .image)
        XCTAssertTrue(PreviewContentKind.detect(url: URL(fileURLWithPath: "/tmp/archive.zip")) == .unsupported)
    }

    func testDetectsFileNameFromArtifactURLQuery() {
        let url = URL(string: "http://127.0.0.1:3080/artifacts/download?path=reports%2Fsummary.yaml")!

        XCTAssertTrue(PreviewContentKind.sourceFileName(for: url) == "summary.yaml")
        XCTAssertTrue(PreviewContentKind.detect(url: url) == .text)
    }

    func testMimeTypeCanClassifyExtensionlessArtifact() {
        let url = URL(string: "http://127.0.0.1:3080/artifacts/42")!

        XCTAssertTrue(PreviewContentKind.detect(url: url, mimeType: "image/svg+xml") == .svg)
        XCTAssertTrue(PreviewContentKind.detect(url: url, mimeType: "application/json; charset=utf-8") == .text)
    }
}
