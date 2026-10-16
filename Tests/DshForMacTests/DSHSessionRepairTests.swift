import AppKit
import WebKit
import XCTest
@testable import DshForMac

@MainActor
final class DSHSessionRepairTests: XCTestCase {
    func testRequestRejectsInvalidIdentitiesAndNoncanonicalLogNames() {
        let file = "/tmp/sessions/project/session-fixture/session.v4.jsonl.zstd"
        XCTAssertNotNil(DSHSessionRepairRequest(payload: ["sessionId": "session-fixture", "file": file]))
        for payload in [
            ["sessionId": "../escape", "file": file],
            ["sessionId": "session-other", "file": file],
            ["sessionId": "session-fixture", "file": "relative/session.v4.jsonl.zstd"],
            ["sessionId": "session-fixture", "file": file + "\n"],
            ["sessionId": "session-fixture", "file": file.replacingOccurrences(of: "v4", with: "v5")],
        ] {
            XCTAssertNil(DSHSessionRepairRequest(payload: payload))
        }
    }

    func testRepairButtonAppearsOnlyOnDSHHistoryFormatErrorAndDoesNotAutoRepair() async throws {
        let receiver = SessionRepairMessageReceiver()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(receiver, name: DSHSessionRepairBridge.handlerName)
        let script = DSHSessionRepairBridge.script(token: "fixture-token")
        configuration.userContentController.addUserScript(WKUserScript(
            source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .page
        ))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), configuration: configuration)
        let diagnostic = """
        历史加载失败：failed to observe session "session-fixture": session "session-fixture" contains event type "job/registered" (seq 107) unknown to this harness and not marked ignorable; refusing to interpret the log — it was likely written by a newer harness (raw log: /tmp/sessions/project/session-fixture/session.v4.jsonl.zstd)（gateway/internal）
        """
        webView.loadHTMLString("""
        <!doctype html><body>
        <div id="message">\(diagnostic)</div>
        <div data-chat-flow>
          <div class="_openError_fixture" id="error">\(diagnostic)</div>
          <div class="_openError_fixture" id="network">历史加载失败：network error</div>
        </div></body>
        """, baseURL: URL(string: "http://127.0.0.1:3080/"))
        for _ in 0..<500 {
            if !webView.isLoading { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(webView.isLoading)
        try await webView.evaluateJavaScript(script)
        let initialButtons = try await webView.evaluateJavaScript("document.querySelectorAll('button').length") as? Int
        XCTAssertEqual(initialButtons, 1)
        XCTAssertTrue(receiver.payloads.isEmpty)
        try await webView.evaluateJavaScript("document.querySelector('#error button').click()")
        for _ in 0..<100 {
            if !receiver.payloads.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let payload = try XCTUnwrap(receiver.payloads.first)
        XCTAssertEqual(payload["token"] as? String, "fixture-token")
        XCTAssertEqual(payload["sessionId"] as? String, "session-fixture")
        XCTAssertEqual(payload["file"] as? String, "/tmp/sessions/project/session-fixture/session.v4.jsonl.zstd")
        XCTAssertEqual(Set(payload.keys), Set(["token", "sessionId", "file"]))
        // DSH can reuse the same error element when switching sessions.
        try await webView.evaluateJavaScript("document.getElementById('error').firstChild.textContent = '历史加载失败：network error'")
        try await Task.sleep(nanoseconds: 250_000_000)
        let remainingButtons = try await webView.evaluateJavaScript("document.querySelectorAll('button').length") as? Int
        XCTAssertEqual(remainingButtons, 0)
    }
}

private final class SessionRepairMessageReceiver: NSObject, WKScriptMessageHandler {
    var payloads: [[String: Any]] = []

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let payload = message.body as? [String: Any] { payloads.append(payload) }
    }
}
