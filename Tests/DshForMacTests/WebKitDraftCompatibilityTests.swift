import JavaScriptCore
import WebKit
import XCTest
@testable import DshForMac

final class WebKitDraftCompatibilityTests: XCTestCase {
    private func context(install: Bool = true) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        class Storage {
          constructor() { this.values = new Map(); }
          getItem(key) {
            if (!(this instanceof Storage)) throw new TypeError('Invalid receiver');
            return this.values.has(String(key)) ? this.values.get(String(key)) : null;
          }
          setItem(key, value) {
            if (!(this instanceof Storage)) throw new TypeError('Invalid receiver');
            if (this.quotaExceeded) { const e = new Error('Storage full'); e.name = 'QuotaExceededError'; throw e; }
            this.values.set(String(key), String(value));
          }
        }
        globalThis.localStorage = new Storage();
        globalThis.sessionStorage = new Storage();
        const nativeGet = Storage.prototype.getItem, nativeSet = Storage.prototype.setItem;
        """)
        if install { context.evaluateScript(WebKitDraftCompatibility.script) }
        XCTAssertNil(context.exception)
        return context
    }

    func testSemanticDraftSeedsTheLegacyEditorWithoutChangingStorage() throws {
        let context = try context()
        let result = context.evaluateScript("""
        (() => {
          const key = 'dsh.conversation.test', saved = {draft:{text:'Draft text',references:[]},view:'chat',viewRequest:null};
          const raw = JSON.stringify(saved); nativeSet.call(localStorage,key,raw);
          const draft = JSON.parse(localStorage.getItem(key)).draft;
          return draft.replace(/text/g,'works') === 'Draft works'
            && nativeGet.call(localStorage,key) === raw;
        })()
        """)
        XCTAssertNil(context.exception)
        XCTAssertEqual(result?.toBool(), true)
    }

    func testUnchangedDraftPreservesReferencesAndUnknownFieldsOnWrites() throws {
        let context = try context()
        let result = context.evaluateScript("""
        (() => {
          const key = 'dsh.conversation.test', reference = {source:'file',ref:'test-reference',offset:0,length:4,label:'file'};
          const draft = {text:'file',references:[reference],futureField:true};
          nativeSet.call(localStorage,key,JSON.stringify({draft,view:'chat',extra:42}));
          const legacy = JSON.parse(localStorage.getItem(key)); legacy.view='trajectory';
          localStorage.setItem(key,JSON.stringify(legacy));
          const canonical = JSON.parse(nativeGet.call(localStorage,key));
          return JSON.stringify(canonical.draft) === JSON.stringify(draft)
            && canonical.view === 'trajectory' && canonical.extra === 42;
        })()
        """)
        XCTAssertNil(context.exception)
        XCTAssertEqual(result?.toBool(), true)
    }

    func testEditedDraftRebasesUntouchedReferencesAndRemovesEditedOnes() throws {
        let context = try context()
        let result = context.evaluateScript("""
        (() => {
          const key = 'dsh.conversation.test';
          nativeSet.call(localStorage,key,JSON.stringify({draft:{text:'file tail',references:[
            {source:'file',ref:'first',offset:0,length:4}, {source:'file',ref:'second',offset:5,length:4}
          ]}}));
          localStorage.setItem(key,JSON.stringify({draft:'file added tail'}));
          const inserted = JSON.parse(nativeGet.call(localStorage,key)).draft;
          localStorage.setItem(key,JSON.stringify({draft:'file added edit'}));
          const edited = JSON.parse(nativeGet.call(localStorage,key)).draft;
          localStorage.setItem(key,JSON.stringify({draft:''}));
          const cleared = JSON.parse(nativeGet.call(localStorage,key)).draft;
          return inserted.references.length === 2 && inserted.references[1].offset === 11
            && edited.references.length === 1 && edited.references[0].ref === 'first'
            && cleared.text === '' && cleared.references.length === 0;
        })()
        """)
        XCTAssertNil(context.exception)
        XCTAssertEqual(result?.toBool(), true)
    }

    func testOtherKeysSessionStorageAndMalformedRecordsPassThrough() throws {
        let context = try context()
        let result = context.evaluateScript("""
        (() => {
          const raw = JSON.stringify({draft:{text:'Keep object',references:[]}});
          for(const key of ['other.test','dsh.conversation.']) {
            localStorage.setItem(key,raw); if(localStorage.getItem(key)!==raw) return false;
          }
          const key = 'dsh.conversation.test'; sessionStorage.setItem(key,raw);
          if(sessionStorage.getItem(key)!==raw) return false;
          for(const value of ['bad json','null','[]',JSON.stringify({draft:'Legacy text'}),JSON.stringify({draft:{text:42,references:[]}})]) {
            localStorage.setItem(key,value); if(localStorage.getItem(key)!==value) return false;
          }
          return localStorage.getItem('dsh.conversation.missing') === null;
        })()
        """)
        XCTAssertNil(context.exception)
        XCTAssertEqual(result?.toBool(), true)
    }

    func testRepeatedInstallationAndStorageFailuresRetainNativeSemantics() throws {
        let context = try context()
        context.evaluateScript("const installedGet = Storage.prototype.getItem;")
        context.evaluateScript(WebKitDraftCompatibility.script)
        let result = context.evaluateScript("""
        (() => {
          let quota = false, receiver = false;
          localStorage.quotaExceeded = true;
          try { localStorage.setItem('dsh.conversation.test',JSON.stringify({draft:'new'})); }
          catch(e) { quota = e.name === 'QuotaExceededError'; }
          try { Storage.prototype.getItem.call({},'dsh.conversation.test'); }
          catch(e) { receiver = e instanceof TypeError; }
          return installedGet === Storage.prototype.getItem && quota && receiver
            && !Object.getOwnPropertyDescriptor(Storage.prototype,'getItem').enumerable;
        })()
        """)
        XCTAssertNil(context.exception)
        XCTAssertEqual(result?.toBool(), true)
    }

    func testBlockedLocalStorageDoesNotInstallOrBreakSessionStorage() throws {
        let context = try context(install: false)
        context.evaluateScript("""
        Object.defineProperty(globalThis,'localStorage', {get() { throw new Error('Storage blocked'); }});
        """)
        context.evaluateScript(WebKitDraftCompatibility.script)
        let result = context.evaluateScript("""
        sessionStorage.setItem('test','value');
        Storage.prototype.getItem === nativeGet && sessionStorage.getItem('test') === 'value';
        """)
        XCTAssertNil(context.exception)
        XCTAssertEqual(result?.toBool(), true)
    }

    @MainActor
    func testSwitchingRuntimeAddsAndRemovesOnlyTheLegacyDraftScript() {
        let controller = WKUserContentController()
        let original = WKUserScript(source: "window.otherBridge = true", injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        controller.addUserScript(original)
        for version in ["0.1.6", "0.1.7-rc.2", "0.2.0-rc.1", "0.2.0-rc.2"] {
            WebKitDraftCompatibility.configure(controller, for: version)
            WebKitDraftCompatibility.configure(controller, for: version)
            XCTAssertEqual(controller.userScripts.count, 2)
            XCTAssertTrue(controller.userScripts[0] === original)
            XCTAssertEqual(controller.userScripts[1].injectionTime, .atDocumentStart)
        }
        for version in ["0.2.1-alpha.1", "0.2.1-alpha.2", "0.2.1", "0.3.0", "invalid"] {
            WebKitDraftCompatibility.configure(controller, for: version)
            XCTAssertEqual(controller.userScripts.count, 1)
            XCTAssertTrue(controller.userScripts[0] === original)
        }
        XCTAssertFalse(WebKitDraftCompatibility.isRequired(for: nil))
    }
}
