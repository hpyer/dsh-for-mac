import AppKit
import Testing
import WebKit
@testable import DshForMac

@MainActor
struct TerminalFontTests {
    @Test func scopesSymbolFallbackToTerminalAndPreservesASCIIMetrics() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(
            source: WebKitCompatibility.terminalFontScript,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true
        ))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 200), configuration: configuration)
        webView.loadHTMLString("""
        <style>
        span { display: inline-block; font-size: 13px; }
        .original, .xterm-rows { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
        </style>
        <span id="original" class="original">Hello 123</span>
        <div class="xterm"><span id="terminal" class="xterm-rows">Hello 123</span></div>
        """, baseURL: nil)
        for _ in 0..<500 {
            if !webView.isLoading { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(!webView.isLoading)
        let result = try await webView.evaluateJavaScript("""
        (() => {
          const original = document.getElementById('original');
          const terminal = document.getElementById('terminal');
          return {
            scoped: !getComputedStyle(original).fontFamily.includes('DshForMac'),
            applied: getComputedStyle(terminal).fontFamily.includes('DshForMac Terminal Symbols'),
            sameWidth: original.getBoundingClientRect().width === terminal.getBoundingClientRect().width
          };
        })()
        """)
        let values = try #require(result as? [String: Bool])
        #expect(values["scoped"] == true)
        #expect(values["applied"] == true)
        #expect(values["sameWidth"] == true)

        // When the user's font is installed, verify WebKit can actually load it.
        if NSFont(name: "MesloLGS NF", size: 13) != nil {
            let loaded: Int = try await withCheckedThrowingContinuation { continuation in
                webView.callAsyncJavaScript(
                    "return (await document.fonts.load('13px \"DshForMac Terminal Symbols\"', '\\uE0B0')).length;",
                    arguments: [:], in: nil, in: .page
                ) { result in
                    continuation.resume(with: result.map { ($0 as? Int) ?? 0 })
                }
            }
            #expect(loaded == 1)
        }
    }
}
