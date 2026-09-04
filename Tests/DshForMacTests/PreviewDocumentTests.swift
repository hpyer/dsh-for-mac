import Foundation
import Testing
@testable import DshForMac

struct PreviewDocumentTests {
    @Test func interceptsSupportedProducedFileOpenRPCs() {
        #expect(ProducedFilePreviewBridge.interceptsOpenPathRequest(
            at: URL(string: "http://127.0.0.1:3080/api/session/openWorkspacePath")!
        ))
        #expect(ProducedFilePreviewBridge.interceptsOpenPathRequest(
            at: URL(string: "http://127.0.0.1:3080/api/host/openPath")!
        ))
        #expect(!ProducedFilePreviewBridge.interceptsOpenPathRequest(
            at: URL(string: "http://127.0.0.1:3080/api/session/canOpenWorkspacePath")!
        ))
    }

    @Test func detectsPreviewableFileExtensions() {
        #expect(PreviewContentKind.detect(url: URL(fileURLWithPath: "/tmp/result.ts")) == .text)
        #expect(PreviewContentKind.detect(url: URL(fileURLWithPath: "/tmp/report.md")) == .markdown)
        #expect(PreviewContentKind.detect(url: URL(fileURLWithPath: "/tmp/schema.sql")) == .text)
        #expect(PreviewContentKind.detect(url: URL(fileURLWithPath: "/tmp/Example.java")) == .text)
        #expect(PreviewContentKind.detect(url: URL(fileURLWithPath: "/tmp/Component.vue")) == .text)
        #expect(PreviewContentKind.detect(url: URL(fileURLWithPath: "/tmp/chart.svg")) == .svg)
        #expect(PreviewContentKind.detect(url: URL(fileURLWithPath: "/tmp/screenshot.png")) == .image)
        #expect(PreviewContentKind.detect(url: URL(fileURLWithPath: "/tmp/archive.zip")) == .unsupported)
    }

    @Test func detectsFileNameFromArtifactURLQuery() {
        let url = URL(string: "http://127.0.0.1:3080/artifacts/download?path=reports%2Fsummary.yaml")!

        #expect(PreviewContentKind.sourceFileName(for: url) == "summary.yaml")
        #expect(PreviewContentKind.detect(url: url) == .text)
    }

    @Test func mimeTypeCanClassifyExtensionlessArtifact() {
        let url = URL(string: "http://127.0.0.1:3080/artifacts/42")!

        #expect(PreviewContentKind.detect(url: url, mimeType: "image/svg+xml") == .svg)
        #expect(PreviewContentKind.detect(url: url, mimeType: "application/json; charset=utf-8") == .text)
    }
}
