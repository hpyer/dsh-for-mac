import Foundation
import WebKit

enum WebKitDraftCompatibility {
    /// DSH 0.2.1-alpha.1 introduced semantic draft objects in the same localStorage
    /// key that older releases restore as a string. Project only those records for
    /// legacy pages; keep the canonical object and reference identities on writes.
    static func isRequired(for version: String?) -> Bool {
        guard let version, let parsed = SemanticVersion(string: version),
              let boundary = SemanticVersion(string: "0.2.1-alpha.1") else { return false }
        return parsed < boundary
    }

    static func configure(_ controller: WKUserContentController, for version: String?) {
        let scripts = controller.userScripts.filter { $0.source != script }
        controller.removeAllUserScripts()
        scripts.forEach { controller.addUserScript($0) }
        if isRequired(for: version) {
            controller.addUserScript(WKUserScript(
                source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true
            ))
        }
    }

    static let script = """
    (() => {
      let storage;
      try { storage = localStorage; } catch (_) { return; }
      if (!storage) return;
      const prototype = Storage.prototype;
      const marker = Symbol.for('dshformac.legacy-conversation-draft');
      if (prototype[marker]) return;
      const get = prototype.getItem;
      const set = prototype.setItem;
      const isKey = key => typeof key === 'string'
        && key.startsWith('dsh.conversation.') && key.length > 'dsh.conversation.'.length;
      const isRecord = value => value !== null && typeof value === 'object' && !Array.isArray(value);
      const isDraft = value => isRecord(value)
        && typeof value.text === 'string' && Array.isArray(value.references);
      const readRecord = raw => {
        try { const value = JSON.parse(raw); return isRecord(value) ? value : null; }
        catch (_) { return null; }
      };
      const editDraft = (draft, text) => {
        if (draft.text === text) return draft;
        // Preserve references in unchanged text, rebasing those after an edit.
        // A reference whose text was edited becomes ordinary text in the old editor.
        const before = draft.text;
        let prefix = 0;
        while (prefix < before.length && prefix < text.length && before[prefix] === text[prefix]) prefix++;
        let suffix = 0;
        while (suffix < before.length - prefix && suffix < text.length - prefix
          && before[before.length - suffix - 1] === text[text.length - suffix - 1]) suffix++;
        const delta = text.length - before.length;
        const references = [];
        for (const ref of draft.references) {
          if (!isRecord(ref) || !Number.isInteger(ref.offset) || !Number.isInteger(ref.length)
            || ref.offset < 0 || ref.length <= 0 || ref.offset + ref.length > before.length) continue;
          const end = ref.offset + ref.length;
          let offset;
          if (end <= prefix) offset = ref.offset;
          else if (ref.offset >= before.length - suffix) offset = ref.offset + delta;
          else continue;
          if (text.slice(offset, offset + ref.length) === before.slice(ref.offset, end)) {
            references.push(Object.assign({}, ref, { offset }));
          }
        }
        return Object.assign({}, draft, { text, references });
      };
      const descriptor = name => Object.getOwnPropertyDescriptor(prototype, name);
      Object.defineProperty(prototype, 'getItem', Object.assign({}, descriptor('getItem'), {
        value: function(key) {
          const raw = get.call(this, key);
          if (!isKey(key) || this !== storage) return raw;
          const stored = readRecord(raw);
          if (!stored || !isDraft(stored.draft)) return raw;
          return JSON.stringify(Object.assign({}, stored, { draft: stored.draft.text }));
        }
      }));
      Object.defineProperty(prototype, 'setItem', Object.assign({}, descriptor('setItem'), {
        value: function(key, value) {
          if (isKey(key) && typeof value === 'string' && this === storage) {
            const incoming = readRecord(value);
            if (incoming && typeof incoming.draft === 'string') {
              const stored = readRecord(get.call(this, key));
              if (stored && isDraft(stored.draft)) {
                value = JSON.stringify(Object.assign({}, stored, incoming, {
                  draft: editDraft(stored.draft, incoming.draft)
                }));
              }
            }
          }
          return set.call(this, key, value);
        }
      }));
      Object.defineProperty(prototype, marker, { value: true });
    })();
    """
}
