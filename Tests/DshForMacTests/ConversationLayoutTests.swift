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

    /// DSH is a viewport-sized app shell: its views scroll inside their own
    /// containers and the document itself never scrolls. Plugins append inline
    /// nodes to <body> anyway (a zero-sized sprite/filter holder SVG is the
    /// common pattern) and WebKit still gives them a line box, so the document
    /// grows taller than the viewport; any wheel or focus scroll then shifts the
    /// whole shell, the sidebar stops above the window edge and a strip of page
    /// background shows underneath. The compatibility layer clamps document
    /// scrolling generically instead of patching individual plugins.
    func testPluginsCannotScrollTheAppShell() async throws {
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
        .root { height: 100%; display: flex; flex-direction: column; min-height: 0; }
        .scroller { flex: 1; min-height: 0; overflow-y: auto; }
        .content { height: 2400px; }
        </style>
        <div class="root"><div class="scroller"><div class="content"></div></div></div>
        """, baseURL: nil)
        for _ in 0..<500 {
            if !webView.isLoading { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(webView.isLoading)

        let baseline = try await evaluateDictionary("""
        (() => ({
          overflow: document.scrollingElement.scrollHeight - innerHeight,
          htmlOverflow: getComputedStyle(document.documentElement).overflow,
          rootHeight: document.querySelector('.root').getBoundingClientRect().height
        }))()
        """, in: webView)
        XCTAssertEqual((baseline["overflow"] as? Double) ?? -1, 0, accuracy: 0.5)
        XCTAssertEqual((baseline["rootHeight"] as? Double) ?? 0, 700, accuracy: 1)
        XCTAssertTrue(["hidden", "clip"].contains(baseline["htmlOverflow"] as? String ?? ""))

        // A plugin appends the same kind of node dsh-pet uses: a zero-sized
        // inline SVG that holds filter definitions.
        let appended = try await evaluateDictionary("""
        (() => {
          const NS = 'http://www.w3.org/2000/svg';
          const svg = document.createElementNS(NS, 'svg');
          svg.setAttribute('width', '0');
          svg.setAttribute('height', '0');
          svg.setAttribute('aria-hidden', 'true');
          const defs = document.createElementNS(NS, 'defs');
          const filter = document.createElementNS(NS, 'filter');
          filter.id = 'plugin-filter';
          const transfer = document.createElementNS(NS, 'feComponentTransfer');
          const func = document.createElementNS(NS, 'feFuncA');
          func.setAttribute('type', 'linear');
          func.setAttribute('slope', '1');
          func.setAttribute('intercept', '-0.0039215686');
          transfer.appendChild(func);
          filter.appendChild(transfer);
          defs.appendChild(filter);
          svg.appendChild(defs);
          document.body.appendChild(svg);
          return {
            overflow: document.scrollingElement.scrollHeight - innerHeight,
            filterReachable: document.getElementById('plugin-filter') !== null
          };
        })()
        """, in: webView)
        // Whether a zero-sized inline box still takes a line is WebKit's choice;
        // when it does, the clamp below is what has to keep the shell still.
        let pluginOverflow = (appended["overflow"] as? Double) ?? 0
        XCTAssertEqual(appended["filterReachable"] as? Bool, true)

        let clamped = try await evaluateDictionary("""
        (() => {
          const se = document.scrollingElement;
          window.scrollTo(0, 99999);
          const afterWindowScroll = se.scrollTop;
          se.scrollTop = 60;
          const afterAssign = se.scrollTop;
          document.documentElement.scrollTop = 60;
          const afterHtmlAssign = document.scrollingElement.scrollTop;

          const block = document.createElement('div');
          block.style.cssText = 'height:240px;width:10px';
          document.body.appendChild(block);
          window.scrollTo(0, 99999);
          const afterBlockScroll = se.scrollTop;
          block.remove();

          const scroller = document.querySelector('.scroller');
          scroller.scrollTop = 120;
          return {
            afterWindowScroll, afterAssign, afterHtmlAssign, afterBlockScroll,
            innerScrollTop: scroller.scrollTop,
            documentHeight: se.scrollHeight,
            viewportHeight: innerHeight,
            rootBottom: document.querySelector('.root').getBoundingClientRect().bottom
          };
        })()
        """, in: webView)
        XCTAssertEqual((clamped["afterWindowScroll"] as? Double) ?? -1, 0, accuracy: 0.5)
        XCTAssertEqual((clamped["afterAssign"] as? Double) ?? -1, 0, accuracy: 0.5)
        XCTAssertEqual((clamped["afterHtmlAssign"] as? Double) ?? -1, 0, accuracy: 0.5)
        XCTAssertEqual((clamped["afterBlockScroll"] as? Double) ?? -1, 0, accuracy: 0.5)
        // Inner containers keep scrolling; only the document is clamped.
        XCTAssertEqual((clamped["innerScrollTop"] as? Double) ?? -1, 120, accuracy: 1)
        XCTAssertEqual((clamped["viewportHeight"] as? Double) ?? 0, 700, accuracy: 1)
        // The app root still reaches the bottom edge, so the sidebar cannot end
        // above it even when a plugin left the document taller than the viewport.
        XCTAssertEqual((clamped["rootBottom"] as? Double) ?? 0, 700, accuracy: 1)
        if pluginOverflow > 0.5 {
            XCTAssertGreaterThan(pluginOverflow, 5)
            XCTAssertGreaterThan((clamped["documentHeight"] as? Double) ?? 0, 700)
        }
    }

    private func evaluateDictionary(_ source: String, in webView: WKWebView) async throws -> [String: Any] {
        let result = try await webView.evaluateJavaScript(source)
        return try XCTUnwrap(result as? [String: Any])
    }
}
