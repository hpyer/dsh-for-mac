import AppKit
import JavaScriptCore
import WebKit
import XCTest
@testable import DshForMac

final class WebKitLegacyValueTests: XCTestCase {
    func testArrayFallbacksPreserveInputsAndVisitHoles() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        Object.hasOwn = undefined;
        for (const key of ['at', 'findLast', 'findLastIndex', 'toSorted', 'toReversed']) Array.prototype[key] = undefined;
        String.prototype.at = undefined;
        """)
        context.evaluateScript(WebKitCompatibility.script)
        XCTAssertNil(context.exception)
        let result = context.evaluateScript("""
        (() => {
          const source = [3, , 1], visited = [];
          source[Symbol.iterator] = () => { throw new Error('Must read indices'); };
          const sorted = source.toSorted((a, b) => a - b);
          const reversed = source.toReversed();
          const index = source.findLastIndex((value, index) => { visited.push(index); return value === undefined; });
          const key = Symbol('key'), record = Object.create({ inherited: 1 });
          record[key] = 2; record.hasOwnProperty = null;
          let rejected = false;
          try { Array.prototype.findLast.call(null, () => true); } catch (error) { rejected = error instanceof TypeError; }
          return JSON.stringify({ sorted, reversed, unchanged: source[0] === 3 && !(1 in source),
            dense: 2 in sorted && 1 in reversed, index, visited,
            last: [1, 2, 3].findLast(value => value < 3),
            generic: Array.prototype.at.call({ 0: 'first', 1: 'last', length: 2 }, -1),
            string: 'abc'.at(-1), infinite: source.at(Infinity) === undefined,
            own: Object.hasOwn(record, key), inherited: Object.hasOwn(record, 'inherited'), rejected,
            enumerable: Object.keys(Array.prototype).includes('toSorted') });
        })()
        """)
        XCTAssertNil(context.exception)
        XCTAssertEqual(result?.toString(), #"{"sorted":[1,3,null],"reversed":[1,null,3],"unchanged":true,"dense":true,"index":1,"visited":[2,1],"last":2,"generic":"last","string":"c","infinite":true,"own":true,"inherited":false,"rejected":true,"enumerable":false}"#)
    }

    func testCloneFallbackRetainsCyclesMapKeysAndSharedTypedArrayBuffers() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("structuredClone = undefined")
        context.evaluateScript(WebKitCompatibility.script)
        XCTAssertNil(context.exception)
        let result = context.evaluateScript("""
        (() => {
          const buffer = new Uint8Array([10, 20, 30, 40]).buffer;
          const key = {}, source = { key, buffer, view: new Uint8Array(buffer, 1, 2),
            data: new DataView(buffer, 2, 1), date: new Date(123), regex: /a/gi, big: 123n, missing: undefined };
          source.self = source; source.map = new Map([[key, source]]); source.set = new Set([source]);
          Object.defineProperty(source, '__proto__', { value: { safe: true }, enumerable: true });
          const copy = structuredClone(source);
          copy.view[0] = 99;
          const rejects = value => { try { structuredClone(value); return false; } catch (e) { return e.name === 'DataCloneError'; } };
          return JSON.stringify({ cycle: copy.self === copy, map: copy.map.get(copy.key) === copy,
            set: copy.set.has(copy), views: copy.view.buffer === copy.buffer && copy.data.buffer === copy.buffer,
            original: new Uint8Array(buffer)[1], copied: new Uint8Array(copy.buffer)[1],
            date: copy.date.getTime(), regex: copy.regex.source + copy.regex.flags,
            primitive: copy.big === 123n && Object.hasOwn(copy, 'missing'),
            proto: Object.getPrototypeOf(copy) === Object.prototype && Object.hasOwn(copy, '__proto__'),
            functionRejected: rejects(() => {}), symbolRejected: rejects(Symbol()), weakMapRejected: rejects(new WeakMap()) });
        })()
        """)
        XCTAssertNil(context.exception)
        XCTAssertEqual(result?.toString(), #"{"cycle":true,"map":true,"set":true,"views":true,"original":20,"copied":99,"date":123,"regex":"agi","primitive":true,"proto":true,"functionRejected":true,"symbolRejected":true,"weakMapRejected":true}"#)
    }

    func testBase64EncodesSubarraysPaddingAndLargeFontBuffers() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("Uint8Array.prototype.toBase64 = undefined")
        context.evaluateScript(WebKitCompatibility.script)
        let result = context.evaluateScript("""
        JSON.stringify({ empty: new Uint8Array().toBase64(),
          subarray: new Uint8Array([9, 1, 2, 3, 9]).subarray(1, 4).toBase64(),
          one: new Uint8Array([255]).toBase64(), two: new Uint8Array([255, 254]).toBase64(),
          url: new Uint8Array([255, 254]).toBase64({ alphabet: 'base64url', omitPadding: true }),
          large: new Uint8Array(100000).toBase64().length });
        """)
        XCTAssertNil(context.exception)
        XCTAssertEqual(result?.toString(), #"{"empty":"","subarray":"AQID","one":"/w==","two":"//4=","url":"__4","large":133336}"#)
    }

    func testLeavesExistingAPIsUntouchedOnRepeatedInstallation() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        globalThis.saved = {};
        for (const [object, key] of [[Object, 'hasOwn'], [Array.prototype, 'toSorted'],
          [Array.prototype, 'findLast'], [Uint8Array.prototype, 'toBase64'],
          [ArrayBuffer.prototype, 'transferToFixedLength'], [globalThis, 'structuredClone']]) {
          object[key] = function nativeSentinel() {}; saved[key] = object[key];
        }
        """)
        context.evaluateScript(WebKitCompatibility.script)
        context.evaluateScript(WebKitCompatibility.script)
        XCTAssertNil(context.exception)
        XCTAssertTrue(context.evaluateScript("""
        Object.hasOwn === saved.hasOwn && Array.prototype.toSorted === saved.toSorted
          && Array.prototype.findLast === saved.findLast && Uint8Array.prototype.toBase64 === saved.toBase64
          && ArrayBuffer.prototype.transferToFixedLength === saved.transferToFixedLength
          && structuredClone === saved.structuredClone
        """)?.toBool() == true)
    }

    func testCancellationPreservesExplicitNullReasonAndDisposalHasAStableSymbol() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        globalThis.AbortSignal = class AbortSignal {};
        globalThis.DOMException = class DOMException extends Error { constructor(message, name) { super(message); this.name = name; } };
        """)
        context.evaluateScript(WebKitCompatibility.script)
        let result = context.evaluateScript("""
        (() => {
          const active = new AbortSignal(); active.throwIfAborted();
          const signal = new AbortSignal(); signal.aborted = true; signal.reason = null;
          let nullReason = false; try { signal.throwIfAborted(); } catch (error) { nullReason = error === null; }
          const dispose = Symbol.dispose, owned = { [dispose]() { return 'released'; } };
          return { nullReason, disposed: owned[Symbol.dispose]() === 'released', dispose };
        })()
        """)
        XCTAssertNil(context.exception)
        XCTAssertTrue(result?.forProperty("nullReason")?.toBool() == true)
        XCTAssertTrue(result?.forProperty("disposed")?.toBool() == true)
        context.setObject(result, forKeyedSubscript: "savedDisposal" as NSString)
        context.evaluateScript(WebKitCompatibility.script)
        XCTAssertTrue(context.evaluateScript("savedDisposal.dispose === Symbol.dispose")?.toBool() == true)
    }
}

@MainActor
final class WebKitLegacyBrowserTests: XCTestCase {
    func testPDFWorkerShimPreservesNativeBlobAndFileIdentity() async throws {
        let webView = try await makeWebView(setup: "window.originalBlob = Blob; window.originalFile = File; globalThis.Iterator = undefined;")
        let values = try await evaluate("""
        const file = new File(['document'], 'test.docx');
        const blob = new Blob(['document']);
        const sliced = blob.slice(1);
        const responseBlob = await new Response('document').blob();
        class DerivedBlob extends Blob {}
        const derived = new DerivedBlob(['derived']);
        return {
          wrapped: Blob !== originalBlob,
          prototype: Blob.prototype === originalBlob.prototype,
          file: file instanceof Blob && file instanceof originalFile,
          sliced: sliced instanceof Blob && await sliced.text() === 'ocument',
          response: responseBlob instanceof Blob && await responseBlob.text() === 'document',
          derived: derived instanceof DerivedBlob && derived instanceof Blob && !(blob instanceof DerivedBlob)
        };
        """, in: webView)
        for key in ["wrapped", "prototype", "file", "sliced", "response", "derived"] {
            XCTAssertEqual(values[key] as? Bool, true, key)
        }
    }

    func testDocumentBinaryResponsesPassDSHBlobValidationWithPDFWorkerShim() async throws {
        let webView = try await makeWebView(setup: "window.originalBlob = Blob; globalThis.Iterator = undefined;")
        let values = try await evaluate("""
        // Exercise the native multipart decoder and the Blob guard used by
        // DSH 0.2.1-alpha.2/alpha.4 parseBinaryResponse, before any renderer runs.
        const cases = [
          ['docx', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', [80]],
          ['pptx', 'application/vnd.openxmlformats-officedocument.presentationml.presentation', [80]],
          ['xlsx', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', [80, 75, 3, 4, 0, 255]],
          ['pdf', 'application/pdf', [37, 80, 68, 70, 0, 255]],
          ['png', 'image/png', [137, 80, 78, 71, 0, 255]],
          ['html', 'text/html', [60, 104, 116, 109, 108, 62]],
          ['csv', 'text/csv', [97, 44, 98, 10]],
          ['tsv', 'text/tab-separated-values', [97, 9, 98, 10]],
          ['empty', 'application/octet-stream', []]
        ];
        const results = {};
        for (const [extension, type, bytes] of cases) {
          const envelope = { type: 'server-response', rpcId: 'test',
            result: { ok: true, value: { data: null } },
            attachments: [{ codec: 'bytes', part: 'attachment-0', path: ['data'] }] };
          const form = new FormData();
          form.append('metadata', JSON.stringify(envelope));
          form.append('attachment-0', new originalBlob([new Uint8Array(bytes)], { type }), 'test.' + extension);
          const body = await new Response(form).formData();
          const fields = new Map(body);
          const metadata = fields.get('metadata');
          if (typeof metadata !== 'string') throw new TypeError('connection: invalid binary response fields');
          const parsed = JSON.parse(metadata);
          const attachment = parsed.attachments[0];
          const data = fields.get(attachment.part);
          if (!(data instanceof Blob)) throw new TypeError('connection: invalid binary response fields');
          parsed.result.value.data = new Uint8Array(await data.arrayBuffer());
          results[extension] = parsed.result.value.data.join(',') === bytes.join(',');
        }
        return results;
        """, in: webView)
        for key in ["docx", "pptx", "xlsx", "pdf", "png", "html", "csv", "tsv", "empty"] {
            XCTAssertEqual(values[key] as? Bool, true, key)
        }
    }

    func testBufferTransfersDetachSourcesAndFailedClonesPreserveThem() async throws {
        let webView = try await makeWebView(setup: "structuredClone = undefined; ArrayBuffer.prototype.transferToFixedLength = undefined;")
        let values = try await evaluate("""
        const source = new Uint8Array([1, 2, 3, 4]).buffer;
        const shrunk = source.transferToFixedLength(2);
        const expanded = shrunk.transferToFixedLength(4);
        const input = new Uint8Array([5, 6]).buffer;
        const copy = structuredClone({ input, view: new Uint8Array(input) }, { transfer: [input] });
        const safe = new ArrayBuffer(3);
        let invalid = false, duplicate = false, negative = false, detached = false;
        try { structuredClone({ bad: () => {} }, { transfer: [safe] }); } catch (e) { invalid = e.name === 'DataCloneError'; }
        try { structuredClone({}, { transfer: [safe, safe] }); } catch (e) { duplicate = e.name === 'DataCloneError'; }
        try { safe.transferToFixedLength(-1); } catch (e) { negative = e.name === 'RangeError'; }
        try { source.transferToFixedLength(); } catch (e) { detached = e instanceof TypeError; }
        const blob = new Blob(['font data'], { type: 'text/plain' });
        const blobCopy = structuredClone(blob);
        return { detached: source.byteLength === 0 && shrunk.byteLength === 0 && input.byteLength === 0,
          expanded: Array.from(new Uint8Array(expanded)).join(','),
          copied: copy.view.buffer === copy.input && copy.view.join(',') === '5,6',
          failedPreserves: invalid && duplicate && negative && detached && safe.byteLength === 3,
          blob: blobCopy !== blob && await blobCopy.text() === 'font data' && blobCopy.type === 'text/plain' };
        """, in: webView)
        XCTAssertEqual(values["detached"] as? Bool, true)
        XCTAssertEqual(values["expanded"] as? String, "1,2,0,0")
        XCTAssertEqual(values["copied"] as? Bool, true)
        XCTAssertEqual(values["failedPreserves"] as? Bool, true)
        XCTAssertEqual(values["blob"] as? Bool, true)
    }

    func testPDFStreamsSupportIterationCancellationAndReaderRelease() async throws {
        let webView = try await makeWebView(setup: """
        Response.prototype.bytes = undefined;
        ReadableStream.prototype.values = undefined;
        ReadableStream.prototype[Symbol.asyncIterator] = undefined;
        """)
        let values = try await evaluate("""
        const stream = new ReadableStream({ start(c) { c.enqueue(1); c.enqueue(2); c.close(); } });
        const chunks = []; for await (const chunk of stream) chunks.push(chunk);
        let cancelReason = null;
        const cancelled = new ReadableStream({ start(c) { c.enqueue(3); }, cancel(reason) { cancelReason = reason; } });
        const iterator = cancelled.values(); await iterator.next(); await iterator.return('stop');
        const preserved = new ReadableStream({ start(c) { c.enqueue(4); c.enqueue(5); } });
        const keep = preserved.values({ preventCancel: true }); await keep.next(); await keep.return();
        const reader = preserved.getReader(); const remaining = await reader.read(); reader.releaseLock();
        const broken = new ReadableStream({ start(c) { c.error(new Error('read failed')); } });
        let error = false; try { await broken.values().next(); } catch (e) { error = e.message === 'read failed'; }
        const response = new Response(new Uint8Array([1, 2, 3])); const bytes = await response.bytes();
        let consumed = false; try { await response.bytes(); } catch (e) { consumed = e instanceof TypeError; }
        return { chunks: chunks.join(','), unlocked: !stream.locked && !cancelled.locked && !broken.locked,
          cancelled: cancelReason === 'stop', remaining: remaining.value, error, bytes: bytes.join(','), consumed };
        """, in: webView)
        XCTAssertEqual(values["chunks"] as? String, "1,2")
        XCTAssertEqual(values["unlocked"] as? Bool, true)
        XCTAssertEqual(values["cancelled"] as? Bool, true)
        XCTAssertEqual(values["remaining"] as? Int, 5)
        XCTAssertEqual(values["error"] as? Bool, true)
        XCTAssertEqual(values["bytes"] as? String, "1,2,3")
        XCTAssertEqual(values["consumed"] as? Bool, true)
    }

    func testPDFWorkerInstallerTransfersFontBuffersInARealWorker() async throws {
        let webView = try await makeWebView(setup: "window.originalBlob = Blob; Uint8Array.prototype.toBase64 = undefined;")
        let values = try await evaluate("""
        const wrapped = new Blob(['/* globalThis.pdfjsWorker Iterator.prototype.join */'], { type: 'text/javascript' });
        const source = await wrapped.text();
        const workerSource = 'structuredClone = undefined; ArrayBuffer.prototype.transferToFixedLength = undefined; Uint8Array.prototype.toBase64 = undefined;'
          + source + `
          const buffer = new Uint8Array([1, 2, 3]).buffer;
          const result = buffer.transferToFixedLength(2);
          postMessage({ bytes: new Uint8Array(result).toBase64(), detached: buffer.byteLength === 0 });`;
        const url = URL.createObjectURL(new originalBlob([workerSource], { type: 'text/javascript' }));
        const worker = new Worker(url);
        try {
          return await new Promise((resolve, reject) => {
            const timer = setTimeout(() => reject(new Error('Worker timed out')), 5000);
            worker.onmessage = event => { clearTimeout(timer); resolve(event.data); };
            worker.onerror = event => { clearTimeout(timer); reject(new Error(event.message)); };
          });
        } finally { worker.terminate(); URL.revokeObjectURL(url); }
        """, in: webView)
        XCTAssertEqual(values["bytes"] as? String, "AQI=")
        XCTAssertEqual(values["detached"] as? Bool, true)
    }

    private func makeWebView(setup: String) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(
            source: setup + "\n" + WebKitCompatibility.script,
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page
        ))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        webView.loadHTMLString("<!doctype html><title>Legacy API test</title>", baseURL: URL(string: "http://127.0.0.1:3080/"))
        for _ in 0..<500 {
            if !webView.isLoading { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(webView.isLoading)
        return webView
    }

    private func evaluate(_ source: String, in webView: WKWebView) async throws -> [String: Any] {
        let result: Any = try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(source, arguments: [:], in: nil, in: .page) { result in
                continuation.resume(with: result)
            }
        }
        return try XCTUnwrap(result as? [String: Any])
    }
}
