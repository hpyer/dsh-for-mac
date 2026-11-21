/*
 * DshForMac anchor positioning compatibility for WebKit before Safari 26.
 *
 * DSH 0.2.2-rc.5 positions menus, pickers and popovers with CSS anchor
 * positioning. WebKit on macOS 13/14/15 ignores anchor-name, position-anchor,
 * anchor(), anchor-size() and @position-try, so those surfaces collapse to the
 * top-left or bottom-left corner of the viewport.
 *
 * This script implements the subset DSH uses:
 *   - anchor-name / position-anchor, including React inline styles that WebKit
 *     silently drops before they reach the DOM
 *   - anchor() in top/right/bottom/left and anchor-size() in width/height/min-width
 *   - position-try-fallbacks with @position-try rules
 *   - align-self / justify-self within the inset-modified containing block
 *
 * It does nothing when the browser implements anchor positioning natively.
 */
(() => {
  if (window.__dshForMacAnchorPositioning) return;
  if (typeof CSS === 'undefined' || typeof CSS.supports !== 'function') return;
  if (CSS.supports('anchor-name: --dsh-probe')) return;
  if (typeof document === 'undefined' || typeof getComputedStyle !== 'function') return;

  const WATCHED = new Set([
    'anchor-name', 'anchor-scope', 'position-anchor', 'position-area',
    'position-try', 'position-try-fallbacks', 'position-visibility',
  ]);
  const SIZED_PROPERTIES = new Set(['top', 'right', 'bottom', 'left', 'width', 'height', 'min-width', 'max-width', 'min-height', 'max-height']);
  const MEASURE_PROPERTIES = ['top', 'right', 'bottom', 'left', 'width', 'height', 'min-width'];

  const STYLE_STORE = new WeakMap();
  const STYLE_OWNERS = new WeakMap();
  const INLINE_ANCHORS = new Map();
  const OWNED_ANCHORS = new WeakMap();
  const APPLIED = new WeakMap();
  const SHEET_ORDER = new Map();
  const SHEET_RULES = new Map();
  const SHEET_TEXT = new Map();

  const STATE = {
    rules: [],
    anchorNameRules: [],
    tryRules: new Map(),
    targets: new Set(),
    probe: null,
    scheduled: false,
    bootstrapped: false,
    busy: false,
    sheetSequence: 0,
    styleObserver: null,
    domObserver: null,
    resizeObserver: null,
    retryTimer: null,
    throttleTimer: null,
    retryDelay: 40,
    attempts: new WeakMap(),
    failures: [],
    stats: { refreshes: 0, positioned: 0, failed: 0 },
  };

  // ------------------------------------------------------------ style patch

  const nativeSetProperty = CSSStyleDeclaration.prototype.setProperty;
  const nativeGetPropertyValue = CSSStyleDeclaration.prototype.getPropertyValue;
  const nativeRemoveProperty = CSSStyleDeclaration.prototype.removeProperty;
  const nativeGetPropertyPriority = CSSStyleDeclaration.prototype.getPropertyPriority;

  function styleMap(declaration, create) {
    let map = STYLE_STORE.get(declaration);
    if (!map && create) {
      map = new Map();
      STYLE_STORE.set(declaration, map);
    }
    return map;
  }

  function ownerOf(declaration) {
    const owner = STYLE_OWNERS.get(declaration);
    if (owner) return owner;
    // The style getter is patched before DSH runs, but a declaration created
    // earlier can still be resolved by scanning once.
    for (const element of document.querySelectorAll('*')) {
      if (element.style === declaration) {
        STYLE_OWNERS.set(declaration, element);
        return element;
      }
    }
    return null;
  }

  function registerAnchorNames(element, value) {
    if (!element) return;
    const previous = OWNED_ANCHORS.get(element);
    if (previous) {
      for (const name of previous) {
        const set = INLINE_ANCHORS.get(name);
        if (set) {
          set.delete(element);
          if (set.size === 0) INLINE_ANCHORS.delete(name);
        }
      }
    }
    const names = new Set();
    for (const part of String(value || '').split(',')) {
      const name = part.trim();
      if (name.startsWith('--')) names.add(name);
    }
    if (names.size) {
      OWNED_ANCHORS.set(element, names);
      for (const name of names) {
        let set = INLINE_ANCHORS.get(name);
        if (!set) {
          set = new Set();
          INLINE_ANCHORS.set(name, set);
        }
        set.add(element);
      }
    } else {
      OWNED_ANCHORS.delete(element);
    }
    scheduleRefresh();
  }

  function writeWatched(declaration, property, value) {
    const text = value === null || value === undefined ? '' : String(value).trim();
    const map = styleMap(declaration, true);
    if (!text) {
      map.delete(property);
      if (property === 'anchor-name') registerAnchorNames(ownerOf(declaration), '');
      return;
    }
    map.set(property, text);
    if (property === 'anchor-name') registerAnchorNames(ownerOf(declaration), text);
    else if (property === 'position-anchor') scheduleRefresh();
  }

  function defineMethod(target, name, value) {
    Object.defineProperty(target, name, {
      configurable: true,
      writable: true,
      enumerable: false,
      value,
    });
  }

  defineMethod(CSSStyleDeclaration.prototype, 'setProperty', function(property, value, priority) {
    const name = String(property).toLowerCase();
    if (WATCHED.has(name)) {
      writeWatched(this, name, value);
      return;
    }
    return nativeSetProperty.call(this, property, value, priority);
  });
  defineMethod(CSSStyleDeclaration.prototype, 'getPropertyValue', function(property) {
    const name = String(property).toLowerCase();
    if (WATCHED.has(name)) {
      const map = STYLE_STORE.get(this);
      return map && map.has(name) ? map.get(name) : '';
    }
    return nativeGetPropertyValue.call(this, property);
  });
  defineMethod(CSSStyleDeclaration.prototype, 'removeProperty', function(property) {
    const name = String(property).toLowerCase();
    if (WATCHED.has(name)) {
      const map = STYLE_STORE.get(this);
      const previous = map && map.has(name) ? map.get(name) : '';
      if (map) map.delete(name);
      if (name === 'anchor-name') registerAnchorNames(ownerOf(this), '');
      else if (name === 'position-anchor') scheduleRefresh();
      return previous;
    }
    return nativeRemoveProperty.call(this, property);
  });
  defineMethod(CSSStyleDeclaration.prototype, 'getPropertyPriority', function(property) {
    return WATCHED.has(String(property).toLowerCase()) ? '' : nativeGetPropertyPriority.call(this, property);
  });

  for (const [camel, kebab] of [
    ['anchorName', 'anchor-name'],
    ['anchorScope', 'anchor-scope'],
    ['positionAnchor', 'position-anchor'],
    ['positionArea', 'position-area'],
    ['positionTry', 'position-try'],
    ['positionTryFallbacks', 'position-try-fallbacks'],
    ['positionVisibility', 'position-visibility'],
  ]) {
    Object.defineProperty(CSSStyleDeclaration.prototype, camel, {
      configurable: true,
      enumerable: false,
      get() { return this.getPropertyValue(kebab); },
      set(value) {
        if (value === null || value === undefined || value === '') this.removeProperty(kebab);
        else this.setProperty(kebab, value);
      },
    });
  }

  let styleDescriptor = null;
  for (let proto = HTMLElement.prototype; proto && !styleDescriptor; proto = Object.getPrototypeOf(proto)) {
    styleDescriptor = Object.getOwnPropertyDescriptor(proto, 'style');
  }
  if (styleDescriptor && styleDescriptor.get) {
    try {
      Object.defineProperty(HTMLElement.prototype, 'style', {
        configurable: true,
        enumerable: styleDescriptor.enumerable,
        get() {
          const value = styleDescriptor.get.call(this);
          STYLE_OWNERS.set(value, this);
          return value;
        },
        set: styleDescriptor.set
          ? function(value) { styleDescriptor.set.call(this, value); }
          : undefined,
      });
    } catch (_) {}
  }

  function adoptStyleAttribute(element) {
    const text = element.getAttribute && element.getAttribute('style');
    if (!text || !/anchor|position-try/i.test(text)) return;
    const declaration = element.style;
    for (const { property, value } of parseDeclarations(text)) {
      if (WATCHED.has(property) && !declaration.getPropertyValue(property)) {
        writeWatched(declaration, property, value);
      }
    }
  }

  // ------------------------------------------------------------- css parser

  function parseDeclarations(text) {
    const declarations = [];
    let start = 0;
    let depth = 0;
    let quote = null;
    for (let index = 0; index <= text.length; index += 1) {
      const character = text[index];
      if (quote) {
        if (character === '\\') index += 1;
        else if (character === quote) quote = null;
        continue;
      }
      if (character === '"' || character === "'") { quote = character; continue; }
      if (character === '(') { depth += 1; continue; }
      if (character === ')') { depth = Math.max(0, depth - 1); continue; }
      if ((character === ';' || index === text.length) && depth === 0) {
        const part = text.slice(start, index).trim();
        start = index + 1;
        if (!part) continue;
        let colon = -1;
        let nested = 0;
        let innerQuote = null;
        for (let at = 0; at < part.length; at += 1) {
          const ch = part[at];
          if (innerQuote) {
            if (ch === '\\') at += 1;
            else if (ch === innerQuote) innerQuote = null;
            continue;
          }
          if (ch === '"' || ch === "'") { innerQuote = ch; continue; }
          if (ch === '(') nested += 1;
          else if (ch === ')') nested = Math.max(0, nested - 1);
          else if (ch === ':' && nested === 0) { colon = at; break; }
        }
        if (colon < 0) continue;
        const property = part.slice(0, colon).trim().toLowerCase();
        let value = part.slice(colon + 1).trim();
        let important = false;
        if (/!\s*important\s*$/i.test(value)) {
          important = true;
          value = value.replace(/!\s*important\s*$/i, '').trim();
        }
        if (property) declarations.push({ property, value, important });
      }
    }
    return declarations;
  }

  function isAnchorRelated(declarations) {
    for (const { property, value } of declarations) {
      if (WATCHED.has(property)) return true;
      if (SIZED_PROPERTIES.has(property) && /anchor(?:-size)?\s*\(/i.test(value)) return true;
    }
    return false;
  }

  function skipWhitespaceAndComments(text, index) {
    let at = index;
    while (at < text.length) {
      if (/\s/.test(text[at])) { at += 1; continue; }
      if (text[at] === '/' && text[at + 1] === '*') {
        const end = text.indexOf('*/', at + 2);
        at = end < 0 ? text.length : end + 2;
        continue;
      }
      break;
    }
    return at;
  }

  function findBlockEnd(text, start) {
    let depth = 1;
    let quote = null;
    let at = start;
    while (at < text.length) {
      const character = text[at];
      if (quote) {
        if (character === '\\') at += 1;
        else if (character === quote) quote = null;
        at += 1;
        continue;
      }
      if (character === '/' && text[at + 1] === '*') {
        const end = text.indexOf('*/', at + 2);
        at = end < 0 ? text.length : end + 2;
        continue;
      }
      if (character === '"' || character === "'") { quote = character; at += 1; continue; }
      if (character === '{') depth += 1;
      else if (character === '}') {
        depth -= 1;
        if (depth === 0) return at;
      }
      at += 1;
    }
    return text.length;
  }

  function parseStylesheet(text, sheetOrderBase, sheet) {
    let index = 0;
    let ruleIndex = 0;
    const walk = (source, conditions) => {
      let at = 0;
      while (at < source.length) {
        at = skipWhitespaceAndComments(source, at);
        if (at >= source.length) break;
        if (source[at] === '}') { at += 1; continue; }
        const start = at;
        let depth = 0;
        let quote = null;
        for (; at < source.length; at += 1) {
          const character = source[at];
          if (quote) {
            if (character === '\\') at += 1;
            else if (character === quote) quote = null;
            continue;
          }
          if (character === '/' && source[at + 1] === '*') {
            const end = source.indexOf('*/', at + 2);
            at = end < 0 ? source.length : end + 2;
            continue;
          }
          if (character === '"' || character === "'") { quote = character; continue; }
          if (character === '(') { depth += 1; continue; }
          if (character === ')') { depth = Math.max(0, depth - 1); continue; }
          if (depth === 0 && (character === '{' || character === ';')) break;
        }
        const prelude = source.slice(start, at).trim();
        if (!prelude) { at += 1; continue; }
        if (source[at] === ';') { at += 1; continue; }
        const blockEnd = findBlockEnd(source, at + 1);
        const block = source.slice(at + 1, blockEnd);
        at = blockEnd + 1;
        const lower = prelude.toLowerCase();
        if (lower.startsWith('@media')) {
          walk(block, conditions.concat([{ type: 'media', query: prelude.slice(6).trim() }]));
          continue;
        }
        if (lower.startsWith('@supports')) {
          walk(block, conditions.concat([{ type: 'supports', query: prelude.slice(8).trim() }]));
          continue;
        }
        if (lower.startsWith('@layer') || lower.startsWith('@container') || lower.startsWith('@scope')) {
          walk(block, conditions);
          continue;
        }
        if (lower.startsWith('@position-try')) {
          const name = prelude.slice('@position-try'.length).trim().split(/\s+/)[0];
          if (name.startsWith('--')) sheet.tryRules.set(name, parseDeclarations(block));
          continue;
        }
        if (lower.startsWith('@')) continue;
        const declarations = parseDeclarations(block);
        if (!isAnchorRelated(declarations)) continue;
        sheet.rules.push({
          selector: prelude,
          conditions,
          declarations,
          order: sheetOrderBase + ruleIndex,
        });
        ruleIndex += 1;
      }
    };
    walk(text, []);
    return sheet;
  }

  function parseSheetText(key, text) {
    const previous = SHEET_TEXT.get(key);
    if (previous === text) return;
    SHEET_TEXT.set(key, text);
    if (!SHEET_ORDER.has(key)) {
      STATE.sheetSequence += 1;
      SHEET_ORDER.set(key, STATE.sheetSequence * 100000);
    }
    const sheet = { rules: [], tryRules: new Map() };
    parseStylesheet(text, SHEET_ORDER.get(key), sheet);
    SHEET_RULES.set(key, sheet);
    rebuildRuleIndex();
  }

  function rebuildRuleIndex() {
    STATE.rules = [];
    STATE.anchorNameRules = [];
    STATE.tryRules = new Map();
    for (const sheet of SHEET_RULES.values()) {
      for (const rule of sheet.rules) {
        STATE.rules.push(rule);
        if (rule.declarations.some(({ property }) => property === 'anchor-name')) STATE.anchorNameRules.push(rule);
      }
      for (const [name, declarations] of sheet.tryRules) STATE.tryRules.set(name, declarations);
    }
    STATE.rules.sort((a, b) => a.order - b.order);
    STATE.anchorNameRules.sort((a, b) => a.order - b.order);
    scheduleRefresh();
  }

  function collectSheets() {
    for (const node of document.querySelectorAll('style, link[rel~="stylesheet"]')) {
      if (node.tagName === 'STYLE') {
        const text = node.textContent || '';
        if (text && /anchor|position-try/i.test(text)) parseSheetText(node, text);
      } else if (node.tagName === 'LINK') {
        const href = node.href;
        if (!href || SHEET_ORDER.has(href)) continue;
        STATE.sheetSequence += 1;
        SHEET_ORDER.set(href, STATE.sheetSequence * 100000);
        fetch(href)
          .then((response) => response.ok ? response.text() : '')
          .then((text) => { if (text) parseSheetText(href, text); })
          .catch(() => {});
      }
    }
  }

  // --------------------------------------------------------------- helpers

  function mediaMatches(conditions) {
    for (const condition of conditions) {
      if (condition.type === 'media' && !window.matchMedia(condition.query).matches) return false;
      if (condition.type === 'supports' && !supportsCondition(condition.query)) return false;
    }
    return true;
  }

  function supportsCondition(query) {
    const text = String(query || '').trim();
    if (!text) return true;
    if (/^not\s+/i.test(text)) return !supportsCondition(text.replace(/^not\s+/i, ''));
    const orParts = splitTopLevel(text, 'or');
    if (orParts.length > 1) return orParts.some(supportsCondition);
    const andParts = splitTopLevel(text, 'and');
    if (andParts.length > 1) return andParts.every(supportsCondition);
    const match = /^\(?\s*([a-z-]+)\s*:\s*([^)]+?)\s*\)?$/i.exec(text);
    if (match) {
      try { return CSS.supports(match[1].trim(), match[2].trim()); } catch (_) { return false; }
    }
    return true;
  }

  function splitTopLevel(text, keyword) {
    const parts = [];
    let start = 0;
    let depth = 0;
    let quote = null;
    const pattern = new RegExp('\\s+' + keyword + '\\s+', 'i');
    for (let index = 0; index < text.length; index += 1) {
      const character = text[index];
      if (quote) {
        if (character === '\\') index += 1;
        else if (character === quote) quote = null;
        continue;
      }
      if (character === '"' || character === "'") { quote = character; continue; }
      if (character === '(') depth += 1;
      else if (character === ')') depth = Math.max(0, depth - 1);
      else if (depth === 0) {
        const found = pattern.exec(text.slice(index));
        if (found && found.index === 0) {
          parts.push(text.slice(start, index).trim());
          index += found[0].length - 1;
          start = index + 1;
        }
      }
    }
    parts.push(text.slice(start).trim());
    return parts.filter(Boolean);
  }

  function resolveVars(value, element) {
    let text = String(value);
    for (let guard = 0; guard < 30; guard += 1) {
      const start = text.indexOf('var(');
      if (start < 0) return text;
      let depth = 0;
      let end = -1;
      for (let index = start + 3; index < text.length; index += 1) {
        if (text[index] === '(') depth += 1;
        else if (text[index] === ')') {
          depth -= 1;
          if (depth === 0) { end = index; break; }
        }
      }
      if (end < 0) return '';
      const inner = text.slice(start + 4, end);
      let comma = -1;
      let innerDepth = 0;
      for (let index = 0; index < inner.length; index += 1) {
        if (inner[index] === '(') innerDepth += 1;
        else if (inner[index] === ')') innerDepth -= 1;
        else if (inner[index] === ',' && innerDepth === 0) { comma = index; break; }
      }
      const name = (comma < 0 ? inner : inner.slice(0, comma)).trim();
      const fallback = comma < 0 ? '' : inner.slice(comma + 1).trim();
      const computed = getComputedStyle(element).getPropertyValue(name).trim();
      const replacement = computed || (comma >= 0 ? resolveVars(fallback, element) : '');
      if (!replacement) return '';
      text = text.slice(0, start) + replacement + text.slice(end + 1);
    }
    return text;
  }

  function probeElement() {
    if (STATE.probe && STATE.probe.isConnected) return STATE.probe;
    const probe = document.createElement('div');
    probe.setAttribute('data-dsh-anchor-probe', '');
    probe.setAttribute('aria-hidden', 'true');
    probe.style.cssText = 'position:fixed;left:0;top:0;width:0;height:0;visibility:hidden;pointer-events:none;contain:strict;';
    (document.body || document.documentElement).appendChild(probe);
    STATE.probe = probe;
    return probe;
  }

  function evaluateLength(property, value) {
    const text = value === null || value === undefined ? '' : String(value).trim();
    if (!text || text === 'auto') return 'auto';
    const probe = probeElement();
    try {
      probe.style.removeProperty(property);
      probe.style.setProperty(property, text);
      const computed = getComputedStyle(probe).getPropertyValue(property);
      probe.style.removeProperty(property);
      if (!computed || computed === 'auto') return 'auto';
      const number = parseFloat(computed);
      return Number.isFinite(number) ? number : null;
    } catch (_) {
      try { probe.style.removeProperty(property); } catch (_) {}
      return null;
    }
  }

  function viewportSize() {
    const root = document.documentElement;
    return {
      width: root.clientWidth || window.innerWidth || 0,
      height: root.clientHeight || window.innerHeight || 0,
    };
  }

  function rectOf(element) {
    const rect = element.getBoundingClientRect();
    return { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom, width: rect.width, height: rect.height };
  }

  function documentOrderCompare(a, b) {
    if (a === b) return 0;
    return a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1;
  }

  function isUsableAnchor(element) {
    if (!element || !element.isConnected) return false;
    const style = getComputedStyle(element);
    if (style.display === 'none' || style.visibility === 'hidden') return false;
    return element.getClientRects().length > 0;
  }

  function anchorElementsForName(name) {
    const candidates = new Set(INLINE_ANCHORS.get(name) || []);
    for (const rule of STATE.anchorNameRules) {
      if (!mediaMatches(rule.conditions)) continue;
      let elements;
      try { elements = document.querySelectorAll(rule.selector); } catch (_) { continue; }
      for (const element of elements) {
        let value = inlineValue(element, 'anchor-name');
        if (!value) {
          const declaration = winningDeclaration(element, 'anchor-name');
          if (!declaration) continue;
          value = declaration.value;
        }
        value = resolveVars(value, element);
        if (!value) continue;
        for (const part of value.split(',')) {
          if (part.trim() === name) { candidates.add(element); break; }
        }
      }
    }
    const usable = Array.from(candidates).filter(isUsableAnchor).sort(documentOrderCompare);
    return usable.length ? usable[usable.length - 1] : null;
  }

  function winningDeclaration(element, property) {
    let winner = null;
    for (const rule of STATE.rules) {
      if (!mediaMatches(rule.conditions)) continue;
      let matches = false;
      try { matches = element.matches(rule.selector); } catch (_) { matches = false; }
      if (!matches) continue;
      for (const declaration of rule.declarations) {
        if (declaration.property !== property) continue;
        if (!winner || declaration.important || !winner.important) winner = declaration;
      }
    }
    return winner;
  }

  function declarationsFor(element) {
    const values = new Map();
    for (const rule of STATE.rules) {
      if (!mediaMatches(rule.conditions)) continue;
      let matches = false;
      try { matches = element.matches(rule.selector); } catch (_) { matches = false; }
      if (!matches) continue;
      for (const declaration of rule.declarations) {
        const previous = values.get(declaration.property);
        if (!previous || declaration.important || !previous.important) values.set(declaration.property, declaration);
      }
    }
    return values;
  }

  function inlineValue(element, property) {
    const map = STYLE_STORE.get(element.style);
    return map ? map.get(property) : undefined;
  }

  function anchorNameFor(element, declarations) {
    const inline = inlineValue(element, 'position-anchor');
    if (inline) return resolveVars(inline, element) || null;
    const declaration = declarations.get('position-anchor');
    if (declaration) {
      const value = resolveVars(declaration.value, element);
      if (value === 'none') return null;
      if (value && value !== 'auto' && value !== 'normal') return value;
    }
    const attribute = element.getAttribute && element.getAttribute('anchor');
    return attribute || null;
  }

  function fallbackNames(element, declarations) {
    const declaration = declarations.get('position-try-fallbacks') || declarations.get('position-try');
    if (!declaration) return [];
    const value = resolveVars(declaration.value, element);
    const names = [];
    for (const part of value.split(',')) {
      const name = part.trim();
      if (name.startsWith('--') && STATE.tryRules.has(name)) names.push(name);
    }
    return names;
  }

  // --------------------------------------------------------------- geometry

  function appliedProperties(element) {
    let properties = APPLIED.get(element);
    if (!properties) {
      properties = new Set();
      APPLIED.set(element, properties);
    }
    return properties;
  }

  function setApplied(element, property, value) {
    element.style.setProperty(property, value);
    appliedProperties(element).add(property);
  }

  function removeApplied(element, property) {
    const properties = APPLIED.get(element);
    if (!properties || !properties.has(property)) return;
    element.style.removeProperty(property);
    properties.delete(property);
  }

  function clearApplied(element) {
    const properties = APPLIED.get(element);
    if (!properties) return;
    for (const property of Array.from(properties)) element.style.removeProperty(property);
    properties.clear();
  }

  function applyResolvedSize(element, resolved) {
    for (const property of ['width', 'height', 'min-width']) {
      const value = resolved.get(property);
      if (typeof value === 'number') setApplied(element, property, value + 'px');
      else removeApplied(element, property);
    }
  }

  function measureNatural(element) {
    const previous = new Map();
    for (const property of MEASURE_PROPERTIES) previous.set(property, element.style.getPropertyValue(property));
    element.style.setProperty('left', '0px');
    element.style.setProperty('top', '0px');
    element.style.setProperty('right', 'auto');
    element.style.setProperty('bottom', 'auto');
    const width = element.offsetWidth;
    const height = element.offsetHeight;
    for (const [property, value] of previous) {
      if (value) element.style.setProperty(property, value);
      else element.style.removeProperty(property);
    }
    return { width, height };
  }

  function resolveInset(element, property, declarations, anchorRect, viewport) {
    const declaration = declarations.get(property);
    if (!declaration) {
      const computed = getComputedStyle(element).getPropertyValue(property).trim();
      if (!computed || computed === 'auto') return 'auto';
      const value = evaluateLength(property, computed);
      return value === null ? 'auto' : value;
    }
    let value = resolveVars(declaration.value, element);
    if (!value || value.trim() === 'auto') return 'auto';
    value = value.replace(/anchor-size\(\s*([a-z-]+)\s*(?:,\s*([^)]*))?\)/gi, (_, size, fallback) => {
      const key = size.trim().toLowerCase();
      if (key === 'width' || key === 'inline-size') return anchorRect.width + 'px';
      if (key === 'height' || key === 'block-size') return anchorRect.height + 'px';
      return fallback ? fallback.trim() : '0px';
    });
    value = value.replace(/anchor\(\s*([a-z-]+)\s*(?:,\s*([^)]*))?\)/gi, (_, side, fallback) => {
      const key = side.trim().toLowerCase();
      const horizontal = property === 'left' || property === 'right';
      let ratio = null;
      if (horizontal) {
        if (key === 'left' || key === 'start' || key === 'self-start') ratio = 0;
        else if (key === 'right' || key === 'end' || key === 'self-end') ratio = 1;
        else if (key === 'center') ratio = 0.5;
        else if (key === 'inside') ratio = 0;
        else if (key === 'outside') ratio = 1;
      } else {
        if (key === 'top' || key === 'start' || key === 'self-start') ratio = 0;
        else if (key === 'bottom' || key === 'end' || key === 'self-end') ratio = 1;
        else if (key === 'center') ratio = 0.5;
        else if (key === 'inside') ratio = 0;
        else if (key === 'outside') ratio = 1;
      }
      if (ratio === null) return fallback ? resolveVars(fallback.trim(), element) : '0px';
      if (horizontal) {
        const position = anchorRect.left + anchorRect.width * ratio;
        return (property === 'left' ? position : viewport.width - position) + 'px';
      }
      const position = anchorRect.top + anchorRect.height * ratio;
      return (property === 'top' ? position : viewport.height - position) + 'px';
    });
    const evaluated = evaluateLength(property, value);
    return evaluated === null ? 'auto' : evaluated;
  }

  function parseAlignment(value) {
    const text = String(value || '').trim().toLowerCase();
    const safe = /(^|\s)safe(\s|$)/.test(text) && !/(^|\s)unsafe(\s|$)/.test(text);
    let alignment = 'start';
    for (const token of text.split(/\s+/)) {
      if (token === 'end' || token === 'self-end' || token === 'flex-end') alignment = 'end';
      else if (token === 'center' || token === 'anchor-center') alignment = 'center';
    }
    return { alignment, safe };
  }

  function computeAxis(startInset, endInset, size, extent, alignment, safe) {
    const hasStart = typeof startInset === 'number';
    const hasEnd = typeof endInset === 'number';
    if (hasStart && hasEnd) {
      const areaStart = startInset;
      const areaEnd = extent - endInset;
      const available = areaEnd - areaStart;
      let effective = alignment;
      if (size > available + 0.5 && safe) effective = 'start';
      if (effective === 'end') return areaEnd - size;
      if (effective === 'center') return areaStart + (available - size) / 2;
      return areaStart;
    }
    if (hasStart) return startInset;
    if (hasEnd) return extent - endInset - size;
    return 0;
  }

  function computeCandidate(element, declarations, anchorRect) {
    const viewport = viewportSize();
    const resolved = new Map();
    for (const property of ['top', 'right', 'bottom', 'left']) {
      resolved.set(property, resolveInset(element, property, declarations, anchorRect, viewport));
    }
    for (const property of ['width', 'height', 'min-width']) {
      const declaration = declarations.get(property);
      // Let ordinary CSS sizing (max-content, fit-content, fixed lengths) do
      // its job; only anchor-size() needs the polyfill.
      if (!declaration || !/anchor-size\s*\(/i.test(declaration.value)) continue;
      const value = resolveInset(element, property, declarations, anchorRect, viewport);
      if (typeof value === 'number') resolved.set(property, value);
    }
    applyResolvedSize(element, resolved);
    const natural = measureNatural(element);
    const width = typeof resolved.get('width') === 'number' ? resolved.get('width') : natural.width;
    const height = typeof resolved.get('height') === 'number' ? resolved.get('height') : natural.height;
    const justifyValue = declarations.has('justify-self')
      ? resolveVars(declarations.get('justify-self').value, element)
      : getComputedStyle(element).justifySelf;
    const alignValue = declarations.has('align-self')
      ? resolveVars(declarations.get('align-self').value, element)
      : getComputedStyle(element).alignSelf;
    const justify = parseAlignment(justifyValue);
    const align = parseAlignment(alignValue);
    const x = computeAxis(resolved.get('left'), resolved.get('right'), width, viewport.width, justify.alignment, justify.safe);
    const y = computeAxis(resolved.get('top'), resolved.get('bottom'), height, viewport.height, align.alignment, align.safe);
    return {
      x, y, width, height,
      fits: x >= -0.5 && y >= -0.5 && x + width <= viewport.width + 0.5 && y + height <= viewport.height + 0.5,
    };
  }

  function applyPosition(element, box) {
    setApplied(element, 'left', Math.round(box.x * 100) / 100 + 'px');
    setApplied(element, 'top', Math.round(box.y * 100) / 100 + 'px');
    setApplied(element, 'right', 'auto');
    setApplied(element, 'bottom', 'auto');
  }

  function positionTarget(element) {
    if (!element.isConnected || element.getClientRects().length === 0) return false;
    // DSH portals every anchored surface with position: fixed, so the
    // viewport is its containing block. Leave absolute-positioned elements
    // alone: their containing block is an ancestor and needs different math.
    if (getComputedStyle(element).position !== 'fixed') return false;
    const associations = declarationsFor(element);
    const name = anchorNameFor(element, associations);
    if (!name) { clearApplied(element); return false; }
    const anchor = anchorElementsForName(name);
    if (!anchor) return false;
    const anchorRect = rectOf(anchor);
    const names = fallbackNames(element, associations);
    const candidates = [associations];
    for (const fallback of names) {
      const declarations = new Map(associations);
      for (const declaration of STATE.tryRules.get(fallback)) declarations.set(declaration.property, declaration);
      candidates.push(declarations);
    }
    let chosen = null;
    for (const candidate of candidates) {
      const box = computeCandidate(element, candidate, anchorRect);
      if (!chosen) chosen = box;
      if (box.fits) { chosen = box; break; }
    }
    if (!chosen) return false;
    applyPosition(element, chosen);
    return true;
  }

  // -------------------------------------------------------------- discovery

  function targetSelectors() {
    const selectors = new Set();
    for (const rule of STATE.rules) {
      if (rule.declarations.some(({ property, value }) =>
        property === 'position-anchor' || (SIZED_PROPERTIES.has(property) && /anchor\s*\(/i.test(value)))) {
        selectors.add(rule.selector);
      }
    }
    return Array.from(selectors);
  }

  function discover() {
    if (!document.body) return;
    const selectors = targetSelectors();
    if (!selectors.length) return;
    const seen = new Set();
    let elements = [];
    for (const selector of selectors) {
      try { elements = document.querySelectorAll(selector); } catch (_) { continue; }
      for (const element of elements) {
        if (!(element instanceof HTMLElement)) continue;
        adoptStyleAttribute(element);
        seen.add(element);
        STATE.targets.add(element);
      }
    }
    for (const element of Array.from(STATE.targets)) {
      if (seen.has(element) && element.isConnected) continue;
      STATE.targets.delete(element);
      STATE.attempts.delete(element);
      if (STATE.resizeObserver) STATE.resizeObserver.unobserve(element);
    }
  }

  function refresh() {
    STATE.scheduled = false;
    if (!STATE.bootstrapped) return;
    STATE.stats.refreshes += 1;
    STATE.busy = true;
    if (STATE.domObserver) STATE.domObserver.disconnect();
    try {
      discover();
      let retry = false;
      const ordered = Array.from(STATE.targets).sort(documentOrderCompare);
      for (const element of ordered) {
        let positioned = false;
        try { positioned = positionTarget(element); }
        catch (error) {
          STATE.stats.failed += 1;
          if (STATE.failures.length < 10) STATE.failures.push({ cls: String(element.className).slice(0, 40), error: String(error) });
        }
        if (positioned) {
          STATE.stats.positioned += 1;
          STATE.attempts.delete(element);
        } else {
          STATE.stats.failed += 1;
          const attempts = (STATE.attempts.get(element) || 0) + 1;
          STATE.attempts.set(element, attempts);
          if (attempts < 40) retry = true;
        }
      }
      if (retry) scheduleRetry();
      if (STATE.resizeObserver) {
        for (const element of STATE.targets) STATE.resizeObserver.observe(element);
      }
    } finally {
      if (STATE.domObserver) {
        STATE.domObserver.observe(document.documentElement, {
          childList: true, subtree: true, attributes: true,
          attributeFilter: ['style', 'class', 'data-anchor-side', 'data-anchor-align', 'anchor'],
        });
      }
      STATE.busy = false;
    }
  }

  function scheduleRefresh() {
    if (STATE.scheduled || !STATE.bootstrapped) return;
    STATE.scheduled = true;
    // setTimeout rather than requestAnimationFrame: rAF is paused while the
    // WebView is occluded, which would also leave the menu unpositioned.
    window.setTimeout(refresh, 0);
  }

  function scheduleRetry() {
    if (STATE.retryTimer) return;
    STATE.retryTimer = window.setTimeout(() => {
      STATE.retryTimer = null;
      scheduleRefresh();
    }, STATE.retryDelay);
  }

  function scheduleRefreshThrottled() {
    if (STATE.throttleTimer) return;
    STATE.throttleTimer = window.setTimeout(() => {
      STATE.throttleTimer = null;
      scheduleRefresh();
    }, 24);
  }

  // ---------------------------------------------------------------- observe

  function collectAndSchedule() {
    collectSheets();
    scheduleRefresh();
  }

  function installObservers() {
    STATE.styleObserver = new MutationObserver((mutations) => {
      let styles = false;
      for (const mutation of mutations) {
        for (const node of mutation.addedNodes) {
          if (node.nodeType !== 1) continue;
          if (node.tagName === 'STYLE' || (node.tagName === 'LINK' && /stylesheet/i.test(node.getAttribute('rel') || ''))) styles = true;
          else if (node.querySelector && node.querySelector('style,link[rel~="stylesheet"]')) styles = true;
        }
      }
      if (styles) collectAndSchedule();
    });
    STATE.styleObserver.observe(document.head || document.documentElement, { childList: true, subtree: true });

    STATE.domObserver = new MutationObserver((mutations) => {
      if (STATE.busy) return;
      if (STATE.targets.size === 0) {
        // Portaled surfaces are inserted as new nodes. While nothing is
        // anchored, ordinary conversation streaming must not schedule work.
        for (const mutation of mutations) {
          if (mutation.type === 'childList' && mutation.addedNodes.length > 0) {
            scheduleRefresh();
            return;
          }
        }
        return;
      }
      scheduleRefreshThrottled();
    });
    STATE.domObserver.observe(document.documentElement, {
      childList: true, subtree: true, attributes: true,
      attributeFilter: ['style', 'class', 'data-anchor-side', 'data-anchor-align', 'anchor'],
    });

    if (typeof ResizeObserver === 'function') {
      STATE.resizeObserver = new ResizeObserver(() => {
        if (!STATE.busy) scheduleRefreshThrottled();
      });
    }

    window.addEventListener('resize', scheduleRefresh, { passive: true });
    window.addEventListener('scroll', scheduleRefreshThrottled, { capture: true, passive: true });
    window.addEventListener('load', scheduleRefresh, { once: true });
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(scheduleRefresh).catch(() => {});
  }

  function bootstrap() {
    if (STATE.bootstrapped) return;
    if (!document.body) {
      document.addEventListener('DOMContentLoaded', bootstrap, { once: true });
      return;
    }
    STATE.bootstrapped = true;
    collectSheets();
    installObservers();
    scheduleRefresh();
  }

  window.__dshForMacAnchorPositioning = {
    version: 1,
    enabled: true,
    parseStylesheet,
    parseDeclarations,
    resolveVars,
    computeAxis,
    parseAlignment,
    refresh,
    declarationsFor,
    resolveInset,
    computeCandidate,
    positionTarget,
    anchorElementsForName,
    evaluateLength,
    viewportSize,
    state: STATE,
    get targetCount() { return STATE.targets.size; },
    get ruleCount() { return STATE.rules.length; },
    get tryRuleCount() { return STATE.tryRules.size; },
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', bootstrap, { once: true });
  } else {
    bootstrap();
  }
})();
