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

    @Test func suppliesStandardAPIsUsedBySessionsAndPDFPreview() throws {
        let context = try #require(JSContext())
        context.evaluateScript(
            """
            Promise.withResolvers = undefined;
            Promise.try = undefined;
            globalThis.URL = class URL {
              constructor(input, base) {
                if (input === 'bad') throw new TypeError('invalid URL');
                this.href = base ? base + input : input;
              }
            };
            RegExp.escape = undefined;
            Math.sumPrecise = undefined;
            Map.prototype.getOrInsert = undefined;
            Map.prototype.getOrInsertComputed = undefined;
            Set.prototype.intersection = undefined;
            Uint8Array.fromBase64 = undefined;
            globalThis.atob = (value) => value === 'AQID' ? String.fromCharCode(1, 2, 3) : '';
            """
        )
        context.evaluateScript(WebKitCompatibility.script)

        #expect(context.exception == nil)
        let result = context.evaluateScript(
            """
            (() => {
              const deferred = Promise.withResolvers();
              const map = new Map([['present', 0]]);
              let computed = 0;
              const existing = map.getOrInsertComputed('present', () => ++computed);
              const inserted = map.getOrInsertComputed('missing', (key) => key.length);
              const bytes = Uint8Array.fromBase64('AQID');
              return JSON.stringify({
                deferred: deferred.promise instanceof Promise
                  && typeof deferred.resolve === 'function'
                  && typeof deferred.reject === 'function',
                promiseTry: Promise.try((a, b) => a + b, 2, 3) instanceof Promise,
                preciseSum: Math.sumPrecise([1e16, 1, -1e16]),
                emptySum: Object.is(Math.sumPrecise([]), -0),
                url: URL.parse('child', 'base/').href,
                invalidURL: URL.parse('bad') === null,
                existing, inserted, computed,
                defaultValue: map.getOrInsert('present', 9),
                intersection: Array.from(new Set([1, 2, 3]).intersection(new Set([2, 3, 4]))),
                escaped: new RegExp(RegExp.escape('a-b.c[1]')).test('a-b.c[1]'),
                notOvermatched: !new RegExp(RegExp.escape('a-b.c[1]')).test('axbxc1'),
                bytes: Array.from(bytes)
              });
            })();
            """
        )
        #expect(
            result?.toString()
                == #"{"deferred":true,"promiseTry":true,"preciseSum":1,"emptySum":true,"url":"base/child","invalidURL":true,"existing":0,"inserted":7,"computed":0,"defaultValue":0,"intersection":[2,3],"escaped":true,"notOvermatched":true,"bytes":[1,2,3]}"#
        )
    }

    @Test func prependsCompatibilityOnlyToTheDSHPDFWorker() throws {
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
            globalThis.pdf = new Blob(
              ['Iterator.prototype.join; globalThis.pdfjsWorker = {};'],
              { type: 'text/javascript' }
            );
            const ordinary = new Blob(['ordinary worker'], { type: 'text/javascript' });
            JSON.stringify({
              pdfParts: pdf.parts.length,
              pdfHasShim: pdf.parts[0].includes("Object.defineProperty(scope, 'Iterator'"),
              pdfHasPromiseShim: pdf.parts[0].includes('scope.Promise.withResolvers'),
              ordinaryParts: ordinary.parts.length,
              ordinarySource: ordinary.parts[0]
            });
            """
        )
        #expect(
            result?.toString()
                == #"{"pdfParts":2,"pdfHasShim":true,"pdfHasPromiseShim":true,"ordinaryParts":1,"ordinarySource":"ordinary worker"}"#
        )

        let workerSource = try #require(context.evaluateScript("pdf.parts[0]")?.toString())
        let worker = try #require(JSContext())
        worker.evaluateScript(
            """
            globalThis.Iterator = undefined;
            globalThis.URL = class URL { constructor(value) { this.href = value; } };
            globalThis.atob = () => String.fromCharCode(1);
            """
        )
        worker.evaluateScript(workerSource)
        #expect(worker.exception == nil)
        #expect(
            worker.evaluateScript(
                """
                typeof Iterator === 'function'
                  && typeof Promise.withResolvers === 'function'
                  && typeof Promise.try === 'function'
                  && typeof URL.parse === 'function'
                  && typeof Map.prototype.getOrInsertComputed === 'function'
                  && typeof Set.prototype.intersection === 'function'
                  && typeof Uint8Array.fromBase64 === 'function'
                """
            )?.toBool() == true
        )
    }
}
