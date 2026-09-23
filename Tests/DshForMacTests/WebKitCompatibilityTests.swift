import JavaScriptCore
import Testing
@testable import DshForMac

@Suite struct WebKitCompatibilityTests {
    @Test func keepsModelMenuButtonsMountedDuringMousePress() throws {
        let context = try #require(JSContext())
        context.evaluateScript(
            """
            globalThis.Element = class Element {
              constructor(tag, parent = null, label = null) {
                this.tag = tag;
                this.parent = parent;
                this.label = label;
              }
              closest(selector) {
                for (let node = this; node; node = node.parent) {
                  if (selector === 'button' && node.tag === 'button') return node;
                  if (selector === '[role="menu"]' && node.tag === 'menu') return node;
                }
                return null;
              }
              getAttribute(name) { return name === 'aria-label' ? this.label : null; }
            };
            globalThis.document = {
              addEventListener(name, listener, capture) {
                this.name = name;
                this.listener = listener;
                this.capture = capture;
              }
            };
            """
        )
        context.evaluateScript(WebKitCompatibility.modelSelectionMouseScript)

        #expect(context.exception == nil)
        let result = context.evaluateScript(
            """
            function press(label, tag = 'button') {
              const menu = new Element('menu', null, label);
              const button = new Element(tag, menu);
              const target = new Element('span', button);
              const event = { target, prevented: false, preventDefault() { this.prevented = true; } };
              document.listener(event);
              return event.prevented;
            }
            JSON.stringify({
              event: document.name,
              capture: document.capture,
              chineseModel: press('模型与推理等级'),
              englishModel: press('Model and reasoning effort'),
              otherMenu: press('Other menu'),
              nonButton: press('模型与推理等级', 'div')
            });
            """
        )
        #expect(
            result?.toString()
                == #"{"event":"mousedown","capture":true,"chineseModel":true,"englishModel":true,"otherMenu":false,"nonButton":false}"#
        )
    }

    @Test func installsIteratorOnTheSharedIteratorPrototype() throws {
        let context = try #require(JSContext())
        context.evaluateScript("globalThis.Iterator = undefined")
        context.evaluateScript(WebKitCompatibility.script)

        #expect(context.exception == nil)
        let result = context.evaluateScript(
            """
            Iterator.prototype.join = function(separator) { return [...this].join(separator); };
            [1, 2, 3].values().join('-');
            """
        )
        #expect(result?.toString() == "1-2-3")
    }

    @Test func preservesAnExistingIteratorImplementation() throws {
        let context = try #require(JSContext())
        context.evaluateScript(
            """
            globalThis.Iterator = function NativeIterator() {};
            globalThis.originalIterator = globalThis.Iterator;
            """
        )
        context.evaluateScript(WebKitCompatibility.script)

        #expect(context.exception == nil)
        #expect(context.evaluateScript("Iterator === originalIterator")?.toBool() == true)
    }

    @Test func prependsTheIteratorShimOnlyToTheDSHPDFWorker() throws {
        let context = try #require(JSContext())
        context.evaluateScript(
            """
            globalThis.Iterator = undefined;
            globalThis.Blob = class NativeBlob {
              constructor(parts, options) {
                this.parts = parts;
                this.options = options;
              }
            };
            """
        )
        context.evaluateScript(WebKitCompatibility.script)

        #expect(context.exception == nil)
        let result = context.evaluateScript(
            """
            const pdf = new Blob(
              ['Iterator.prototype.join; globalThis.pdfjsWorker = {};'],
              { type: 'text/javascript' }
            );
            const ordinary = new Blob(['ordinary worker'], { type: 'text/javascript' });
            JSON.stringify({
              pdfParts: pdf.parts.length,
              pdfHasShim: pdf.parts[0].includes("Object.defineProperty(scope, 'Iterator'"),
              ordinaryParts: ordinary.parts.length,
              ordinarySource: ordinary.parts[0]
            });
            """
        )
        #expect(
            result?.toString()
                == #"{"pdfParts":2,"pdfHasShim":true,"ordinaryParts":1,"ordinarySource":"ordinary worker"}"#
        )
    }
}
