import AppKit
import WebKit
import XCTest
@testable import DshForMac

@MainActor
final class ConversationLayoutTests: XCTestCase {
    func testConversationFillsTheCenterColumnThroughSlotAnchors() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(
            source: WebKitCompatibility.conversationLayoutScript,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true
        ))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration)
        webView.loadHTMLString("""
        <!doctype html>
        <style>
        html, body { height: 100%; margin: 0; }
        .frame { display: grid; height: 100%; grid-template-columns: 220px 1fr; grid-template-rows: 100%; }
        .center { display: flex; flex-direction: column; min-width: 0; overflow: hidden; }
        .root { display: flex; flex-direction: column; height: 100%; min-width: 0; overflow: hidden; }
        header { flex: none; height: 76px; }
        .body { display: flex; flex-direction: column; flex: 1; min-height: 0; position: relative; }
        .scroll { display: flex; flex-direction: column; flex: 1; min-height: 0; overflow-y: auto; }
        .view { display: flex; flex-direction: column; flex: 1 1 0; min-height: 0; overflow: hidden; }
        .composer { flex: none; height: 152px; position: absolute; bottom: 0; left: 0; right: 0; }
        </style>
        <div class="frame"><aside></aside><div class="center">
          <div data-slot="main" style="display: contents">
            <div data-slot="main.conversation" style="display: contents">
              <div class="root" data-phase="active">
                <header></header>
                <div data-slot="conversation.content" style="display: contents">
                  <div class="body" data-conversation-content data-content-phase="active">
                    <div class="scroll" data-conversation-scroll>
                      <div data-slot="conversation.session" style="display: contents">
                        <div class="view"><div id="messages">Messages</div></div>
                      </div>
                      <div class="composer" data-composer-seat><div data-conversation-composer-overlay>Composer</div></div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div></div>
        """, baseURL: nil)
        for _ in 0..<500 {
            if !webView.isLoading { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(webView.isLoading)
        let result = try await webView.evaluateJavaScript("""
        (() => {
          const rect = selector => document.querySelector(selector).getBoundingClientRect();
          return { rootHeight: rect('.root').height, bodyHeight: rect('.body').height,
                   viewHeight: rect('.view').height, composerBottom: rect('.composer').bottom };
        })()
        """)
        let values = try XCTUnwrap(result as? [String: Double])
        XCTAssertEqual(values["rootHeight"] ?? 0, 700, accuracy: 1)
        XCTAssertEqual(values["bodyHeight"] ?? 0, 624, accuracy: 1)
        XCTAssertGreaterThan(values["viewHeight"] ?? 0, 400)
        XCTAssertEqual(values["composerBottom"] ?? 0, 700, accuracy: 1)

        // A percentage-height root becoming auto-sized reproduces the collapsed
        // layout even on a newer WebKit that resolves the upstream height correctly.
        // Removing the fix must collapse the message viewport; reinstalling it
        // must restore the available space without fixed viewport dimensions.
        let collapsed = try await webView.evaluateJavaScript("""
        document.getElementById('dsh-for-mac-conversation-layout').remove();
        document.querySelector('.root').style.height = 'auto';
        document.querySelector('.view').getBoundingClientRect().height;
        """)
        XCTAssertLessThan((collapsed as? Double) ?? 1000, 100)
        try await webView.evaluateJavaScript(WebKitCompatibility.conversationLayoutScript)
        let restored = try await webView.evaluateJavaScript("document.querySelector('.view').getBoundingClientRect().height")
        XCTAssertGreaterThan((restored as? Double) ?? 0, 400)

        webView.frame.size = NSSize(width: 800, height: 500)
        try await Task.sleep(nanoseconds: 50_000_000)
        let resized = try await webView.evaluateJavaScript("""
        (() => {
          document.querySelector('.frame').style.gridTemplateColumns = '220px 1fr 200px';
          const rightbar = document.createElement('aside');
          rightbar.dataset.phase = 'active';
          document.querySelector('.frame').appendChild(rightbar);
          return { rootHeight: document.querySelector('.root').getBoundingClientRect().height,
                   composerBottom: document.querySelector('.composer').getBoundingClientRect().bottom,
                   otherPanelFlexGrow: getComputedStyle(rightbar).flexGrow };
        })()
        """)
        let resizedValues = try XCTUnwrap(resized as? [String: Any])
        XCTAssertEqual((resizedValues["rootHeight"] as? Double) ?? 0, 500, accuracy: 1)
        XCTAssertEqual((resizedValues["composerBottom"] as? Double) ?? 0, 500, accuracy: 1)
        XCTAssertEqual(resizedValues["otherPanelFlexGrow"] as? String, "0")

        // The same resident root also hosts the centered composer of a new chat.
        let hero = try await webView.evaluateJavaScript("""
        (() => {
          document.querySelector('.root').dataset.phase = 'hero';
          document.querySelector('[data-slot="conversation.session"]').remove();
          document.querySelector('.scroll').style.justifyContent = 'center';
          document.querySelector('.composer').style.position = 'static';
          const box = document.querySelector('.composer').getBoundingClientRect();
          return (box.top + box.bottom) / 2;
        })()
        """)
        XCTAssertEqual((hero as? Double) ?? 0, (76 + 500) / 2, accuracy: 1)
    }
}
