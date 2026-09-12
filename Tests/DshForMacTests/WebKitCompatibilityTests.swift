import JavaScriptCore
import Testing
@testable import DshForMac

@Suite struct WebKitCompatibilityTests {
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
