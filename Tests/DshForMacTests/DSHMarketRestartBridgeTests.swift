import AppKit
import WebKit
import XCTest
@testable import DshForMac

@MainActor
final class DSHMarketRestartBridgeTests: XCTestCase {
    func testOnlyInterceptsMarketRestartsAndLeavesFileRequestsToDSH() async throws {
        let configuration = WKWebViewConfiguration()
        let receiver = RestartMessageReceiver()
        configuration.userContentController.add(receiver, name: DSHMarketRestartBridge.handlerName)
        configuration.userContentController.addUserScript(WKUserScript(
            source: """
            window.forwarded = [];
            window.fetch = (input, init) => {
              forwarded.push({ url: input instanceof Request ? input.url : String(input), body: init?.body });
              return Promise.resolve(new Response('DSH', { status: 200 }));
            };
            """,
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page
        ))
        let script = DSHMarketRestartBridge.script(token: "test-restart-token")
        configuration.userContentController.addUserScript(WKUserScript(
            source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page
        ))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), configuration: configuration)
        webView.loadHTMLString("<!doctype html><title>Restart bridge test</title>",
                              baseURL: URL(string: "http://127.0.0.1:3080/"))
        for _ in 0..<500 {
            if !webView.isLoading { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(webView.isLoading)
        // Reinstallation must not double-wrap fetch or send duplicate restarts.
        try await webView.evaluateJavaScript(script)
        let result: Any = try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript("""
            const direct = await fetch('/dsh-market/restart', { method: 'POST' });
            const request = await fetch(new Request('http://127.0.0.1:3080/dsh-market/restart', { method: 'POST' }));
            await fetch('/dsh-market/restart');
            await fetch('http://127.0.0.1:3081/dsh-market/restart', { method: 'POST' });
            await fetch('/api/session/openWorkspacePath', { method: 'POST', body: 'untouched-file-request' });
            await fetch('/api/host/openPath', { method: 'POST', body: 'untouched-legacy-request' });
            window.__DSH_TRANSPORT__ = { fetch: window.fetch };
            // Let the boot-time watcher discover the transport installed later.
            await new Promise(resolve => setTimeout(resolve, 100));
            const transport = await __DSH_TRANSPORT__.fetch('/dsh-market/restart', { method: 'POST' });
            await __DSH_TRANSPORT__.fetch('/api/session/openWorkspacePath', { method: 'POST', body: 'transport-file-request' });
            return { directStatus: direct.status, requestStatus: request.status,
                     transportStatus: transport.status, managed: (await direct.json()).managed,
                     forwardedCount: forwarded.length,
                     bodies: forwarded.filter(item => item.body).map(item => item.body).join(',') };
            """, arguments: [:], in: nil, in: .page) { result in
                continuation.resume(with: result)
            }
        }
        let values = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(values["directStatus"] as? Int, 202)
        XCTAssertEqual(values["requestStatus"] as? Int, 202)
        XCTAssertEqual(values["transportStatus"] as? Int, 202)
        XCTAssertEqual(values["managed"] as? Bool, true)
        XCTAssertEqual(values["forwardedCount"] as? Int, 5)
        XCTAssertEqual(values["bodies"] as? String,
                       "untouched-file-request,untouched-legacy-request,transport-file-request")
        XCTAssertEqual(receiver.tokens, Array(repeating: "test-restart-token", count: 3))
    }
}

private final class RestartMessageReceiver: NSObject, WKScriptMessageHandler {
    var tokens: [String] = []

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let payload = message.body as? [String: Any], let token = payload["token"] as? String {
            tokens.append(token)
        }
    }
}
