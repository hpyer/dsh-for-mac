import JavaScriptCore
import WebKit
import XCTest
@testable import DshForMac

final class WebKitAnchorPositioningTests: XCTestCase {
    private func makeContext(nativeSupport: Bool = false) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(
            """
            globalThis.window = globalThis;
            globalThis.CSS = { supports: () => \(nativeSupport) };
            globalThis.document = {
              readyState: 'loading',
              addEventListener() {},
              querySelectorAll() { return []; },
              documentElement: { clientWidth: 1280, clientHeight: 900 },
              head: null,
              body: null
            };
            globalThis.getComputedStyle = (element) => ({
              getPropertyValue(name) {
                return element && element.vars && element.vars[name] || '';
              },
              justifySelf: 'start',
              alignSelf: 'start'
            });
            globalThis.HTMLElement = function HTMLElement() {};
            globalThis.CSSStyleDeclaration = function CSSStyleDeclaration() {};
            CSSStyleDeclaration.prototype.setProperty = function() {};
            CSSStyleDeclaration.prototype.getPropertyValue = function() { return ''; };
            CSSStyleDeclaration.prototype.removeProperty = function() { return ''; };
            CSSStyleDeclaration.prototype.getPropertyPriority = function() { return ''; };
            """
        )
        return context
    }

    func testInstallsAsASingleDocumentStartScript() {
        let controller = WKUserContentController()
        WebKitAnchorPositioning.configure(controller)
        XCTAssertEqual(controller.userScripts.count, 1)
        XCTAssertEqual(controller.userScripts.first?.injectionTime, .atDocumentStart)
        XCTAssertEqual(controller.userScripts.first?.isForMainFrameOnly, true)
        XCTAssertTrue(controller.userScripts.first?.source.contains("__dshForMacAnchorPositioning") == true)
    }

    func testBundlesTheCompatibilityScript() {
        let script = WebKitAnchorPositioning.script
        XCTAssertFalse(script.isEmpty)
        XCTAssertTrue(script.contains("anchor-name: --dsh-probe"))
        XCTAssertTrue(script.contains("__dshForMacAnchorPositioning"))
        XCTAssertTrue(script.contains("position-try-fallbacks"))
    }

    func testSkipsInstallationWhenAnchorPositioningIsNative() throws {
        let context = try makeContext(nativeSupport: true)
        context.evaluateScript(WebKitAnchorPositioning.script)
        XCTAssertNil(context.exception)
        XCTAssertTrue(
            context.evaluateScript("typeof window.__dshForMacAnchorPositioning")?.toString() == "undefined"
        )
    }

    func testInstallsWithoutANativeAnchorAPI() throws {
        let context = try makeContext()
        context.evaluateScript(WebKitAnchorPositioning.script)
        XCTAssertNil(context.exception)
        XCTAssertTrue(
            context.evaluateScript("typeof window.__dshForMacAnchorPositioning")?.toString() == "object"
        )
    }

    func testKeepsReactInlineAnchorPropertiesOutOfTheNativeStyleParser() throws {
        // WebKit drops anchor-name/position-anchor set through CSSStyleDeclaration
        // on macOS 13-15. React sets them that way, so the polyfill records them.
        let context = try makeContext()
        context.evaluateScript(WebKitAnchorPositioning.script)
        XCTAssertNil(context.exception)
        let result = context.evaluateScript(
            """
            (() => {
              const style = new CSSStyleDeclaration();
              style.positionAnchor = '--panel';
              style.anchorName = '--trigger';
              const anchorName = style.anchorName;
              style.setProperty('position-anchor', '--panel-2');
              style.removeProperty('anchor-name');
              return JSON.stringify({
                anchorName,
                positionAnchor: style.getPropertyValue('position-anchor'),
                removedAnchor: style.getPropertyValue('anchor-name'),
                priority: style.getPropertyPriority('position-anchor')
              });
            })();
            """
        )
        XCTAssertEqual(
            result?.toString(),
            #"{"anchorName":"--trigger","positionAnchor":"--panel-2","removedAnchor":"","priority":""}"#
        )
    }

    func testParsesDeclarationsAndPositionTryBlocks() throws {
        let context = try makeContext()
        context.evaluateScript(WebKitAnchorPositioning.script)
        XCTAssertNil(context.exception)
        let result = context.evaluateScript(
            """
            (() => {
              const api = window.__dshForMacAnchorPositioning;
              const declarations = api.parseDeclarations(
                'top: max(12px, calc(anchor(bottom) + 4px)); position-anchor: --menu !important; color: red'
              );
              const sheet = { rules: [], tryRules: new Map() };
              api.parseStylesheet(
                '.menu { position-anchor: var(--trigger); top: anchor(bottom); }'
                + '@position-try --above { bottom: calc(anchor(top) + 4px); }'
                + '@media (min-width: 1px) { .menu { right: 12px; } }',
                0,
                sheet
              );
              return JSON.stringify({
                declarations,
                rules: sheet.rules.length,
                selector: sheet.rules[0].selector,
                properties: sheet.rules[0].declarations.map(item => item.property),
                tryRules: Array.from(sheet.tryRules.keys())
              });
            })();
            """
        )
        XCTAssertTrue(
            result?.toString() == #"{"declarations":[{"property":"top","value":"max(12px, calc(anchor(bottom) + 4px))","important":false},{"property":"position-anchor","value":"--menu","important":true},{"property":"color","value":"red","important":false}],"rules":1,"selector":".menu","properties":["position-anchor","top"],"tryRules":["--above"]}"#
        )
    }

    func testResolvesCustomPropertyFallbacks() throws {
        let context = try makeContext()
        context.evaluateScript(WebKitAnchorPositioning.script)
        XCTAssertNil(context.exception)
        let result = context.evaluateScript(
            """
            (() => {
              const api = window.__dshForMacAnchorPositioning;
              const element = { vars: { '--space': 'max(4px, 8px)', '--empty': '' } };
              return JSON.stringify({
                nested: api.resolveVars('max(12px, var(--space))', element),
                fallback: api.resolveVars('var(--missing, var(--space))', element),
                empty: api.resolveVars('var(--empty, 3px)', element),
                missing: api.resolveVars('var(--missing)', element)
              });
            })();
            """
        )
        XCTAssertEqual(
            result?.toString(),
            #"{"nested":"max(12px, max(4px, 8px))","fallback":"max(4px, 8px)","empty":"3px","missing":""}"#
        )
    }

    func testAlignsWithinTheInsetModifiedContainingBlock() throws {
        let context = try makeContext()
        context.evaluateScript(WebKitAnchorPositioning.script)
        XCTAssertNil(context.exception)
        let result = context.evaluateScript(
            """
            (() => {
              const api = window.__dshForMacAnchorPositioning;
              return JSON.stringify({
                end: api.computeAxis(100, 12, 200, 1280, 'end', false),
                center: api.computeAxis(100, 12, 200, 1280, 'center', false),
                start: api.computeAxis(100, 12, 200, 1280, 'start', false),
                rightOnly: api.computeAxis('auto', 12, 200, 1280, 'start', false),
                leftOnly: api.computeAxis(100, 'auto', 200, 1280, 'end', false),
                safeEnd: api.computeAxis(100, 12, 1200, 1280, 'end', true),
                unsafeEnd: api.computeAxis(100, 12, 1200, 1280, 'end', false),
                alignment: api.parseAlignment('safe end'),
                defaultAlignment: api.parseAlignment('')
              });
            })();
            """
        )
        XCTAssertEqual(
            result?.toString(),
            #"{"end":1068,"center":584,"start":100,"rightOnly":1068,"leftOnly":100,"safeEnd":100,"unsafeEnd":68,"alignment":{"alignment":"end","safe":true},"defaultAlignment":{"alignment":"start","safe":false}}"#
        )
    }
}
