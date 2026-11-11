// Behavioural test for the sidebar drop-target fallbacks. The DSH plugin runs
// inside a browser, so the test provides the small DOM surface it uses and
// drives the same entry points as WebKit (window drag events) and the native
// host (`__dshForMacWorkspaceDrop2AddProtection.onDragEvent`).
import { readFile } from 'node:fs/promises'
import vm from 'node:vm'
import assert from 'node:assert/strict'

const client = await readFile(new URL('../lib/client.js', import.meta.url), 'utf8')
const overlayId = 'dsh-workspace-drop2add-overlay'
const hintId = 'dsh-workspace-drop2add-hint'

function createDom() {
  const body = makeElement('body')
  const settingsArea = makeElement('div')
  settingsArea.className = 'hHd-Xa_settingsArea'
  body.appendChild(settingsArea)
  const tree = makeElement('div')
  tree.rect = { left: 0, top: 0, width: 280, height: 760, right: 280, bottom: 760 }
  body.appendChild(tree)

  const windowListeners = []
  const documentListeners = []
  const timers = new Map()
  let timerSequence = 0

  const document = {
    body,
    visibilityState: 'visible',
    createElement: (tag) => makeElement(tag),
    createElementNS: (_namespace, tag) => makeElement(tag),
    getElementById: (id) => findById(body, id),
    querySelector: (selector) => {
      if (selector === '[role="tree"]') return tree
      if (selector === 'div.hHd-Xa_settingsArea') return settingsArea
      return null
    },
    querySelectorAll: () => [],
    elementFromPoint: () => tree,
    addEventListener: (type, listener, capture) => documentListeners.push({ type, listener, capture }),
    removeEventListener: (type, listener, capture) => {
      const index = documentListeners.findIndex((entry) => entry.type === type
        && entry.listener === listener && entry.capture === capture)
      if (index >= 0) documentListeners.splice(index, 1)
    }
  }

  const bridgeMessages = []
  const dispatched = []
  const window = {
    document,
    innerWidth: 1200,
    innerHeight: 800,
    webkit: { messageHandlers: { dshWorkspaceDrop2AddBridge: { postMessage: (message) => bridgeMessages.push(message) } } },
    addEventListener: (type, listener, capture) => windowListeners.push({ type, listener, capture }),
    removeEventListener: (type, listener, capture) => {
      const index = windowListeners.findIndex((entry) => entry.type === type
        && entry.listener === listener && entry.capture === capture)
      if (index >= 0) windowListeners.splice(index, 1)
    },
    dispatchEvent: (event) => {
      dispatched.push(event.type)
      for (const entry of [...windowListeners, ...documentListeners]) {
        if (entry.type === event.type) entry.listener(event)
      }
      return true
    },
    setTimeout: (callback, milliseconds) => {
      const id = ++timerSequence
      timers.set(id, { callback, milliseconds })
      return id
    },
    clearTimeout: (id) => timers.delete(id),
    requestAnimationFrame: (callback) => {
      callback()
      return 1
    }
  }

  return {
    window,
    document,
    bridgeMessages,
    dispatched,
    windowListeners,
    documentListeners,
    // Runs every pending watchdog/timeout once, like a much later drag event.
    runPendingTimers() {
      const pending = [...timers.values()]
      timers.clear()
      for (const timer of pending) timer.callback()
    },
    pendingTimerCount: () => timers.size,
    emitWindow(type, event = { type }) {
      for (const entry of [...windowListeners]) {
        if (entry.type === type) entry.listener(event)
      }
    },
    emitDocument(type, event = { type }) {
      for (const entry of [...documentListeners]) {
        if (entry.type === type) entry.listener(event)
      }
    }
  }
}

function makeElement(tag) {
  const element = {
    tagName: String(tag).toUpperCase(),
    style: {},
    dataset: {},
    attributes: {},
    children: [],
    parentElement: null,
    textContent: '',
    innerHTML: '',
    setAttribute(name, value) {
      this.attributes[name] = String(value)
    },
    getAttribute(name) {
      return this.attributes[name] ?? null
    },
    appendChild(child) {
      child.parentElement = this
      this.children.push(child)
      return child
    },
    append(...nodes) {
      for (const node of nodes) this.appendChild(node)
    },
    prepend(...nodes) {
      for (const node of [...nodes].reverse()) {
        node.parentElement = this
        this.children.unshift(node)
      }
    },
    remove() {
      if (!this.parentElement) return
      const index = this.parentElement.children.indexOf(this)
      if (index >= 0) this.parentElement.children.splice(index, 1)
      this.parentElement = null
    },
    getBoundingClientRect() {
      return this.rect ?? { left: 0, top: 0, width: 0, height: 0, right: 0, bottom: 0 }
    }
  }
  Object.defineProperty(element, 'id', {
    get() {
      return this._id ?? ''
    },
    set(value) {
      this._id = value
    }
  })
  return element
}

function findById(root, id) {
  if (root.id === id) return root
  for (const child of root.children) {
    const found = findById(child, id)
    if (found) return found
  }
  return null
}

function dragEvent(overrides = {}) {
  return {
    type: 'dragover',
    clientX: 120,
    clientY: 200,
    dataTransfer: { types: ['Files'] },
    ...overrides
  }
}

async function loadPlugin() {
  const dom = createDom()
  const context = vm.createContext({
    window: dom.window,
    document: dom.document,
    crypto: { randomUUID: () => '00000000-0000-4000-8000-000000000000' },
    console: { info() {}, warn() {}, error() {} },
    Event,
    URL,
    setTimeout: dom.window.setTimeout,
    clearTimeout: dom.window.clearTimeout,
    MutationObserver: class {
      observe() {}
      disconnect() {}
    }
  })
  dom.window.__ModuleLoader__ = { load: ({ factory }) => { dom.plugin = factory() } }
  vm.runInContext(client, context, { filename: 'dsh-workspace-drop2add/lib/client.js' })
  assert.equal(typeof dom.plugin?.apply, 'function', 'plugin factory must expose apply')
  dom.cleanup = dom.plugin.apply({
    get: (name) => (name === 'workspaces'
      ? { create: async ({ path }) => ({ workspaceId: 'workspace', title: path, path }) }
      : undefined)
  })
  return dom
}

function overlay(dom) {
  return dom.document.getElementById(overlayId)
}

function hintDisplay(dom) {
  return dom.document.getElementById(hintId)?.style.display
}

const dom = await loadPlugin()
const protection = dom.window.__dshForMacWorkspaceDrop2AddProtection
assert.ok(protection, 'native bridge handshake must expose the page protection')
assert.equal(hintDisplay(dom), 'block', 'the idle hint should be visible before any drag')

// 1. A drag entering the sidebar shows the target, and the watchdog remains armed.
dom.emitWindow('dragover', dragEvent())
assert.ok(overlay(dom), 'sidebar drag must show the drop target')
assert.equal(protection.isOverSidebar, true)
assert.equal(dom.pendingTimerCount(), 1, 'showing the target must arm the idle watchdog')
assert.equal(hintDisplay(dom), 'none', 'the hint must yield to the drop target')

// Repeated dragover events re-arm the watchdog instead of stacking timers.
dom.emitWindow('dragover', dragEvent())
assert.equal(dom.pendingTimerCount(), 1, 'dragover must re-arm a single watchdog')

// A dragleave inside the sidebar (element transitions) must not flicker the target.
protection.onDragEvent('dragleave')
assert.ok(overlay(dom), 'dragleave inside the sidebar must keep the drop target')

// 2. No further drag event arrives (left the window, cancelled, Finder aborted):
//    the watchdog clears the target.
const dragendsBeforeWatchdog = dom.dispatched.filter((type) => type === 'dragend').length
dom.runPendingTimers()
assert.equal(overlay(dom), null, 'idle watchdog must remove the drop target')
assert.equal(protection.isOverSidebar, false)
assert.equal(hintDisplay(dom), 'block', 'the hint must come back after a failed drag')
assert.equal(
  dom.dispatched.filter((type) => type === 'dragend').length,
  dragendsBeforeWatchdog,
  'the watchdog must not synthesize extra dragend events for DSH'
)

// 3. The native drag destination reports a session end; the target is cleared
//    immediately instead of waiting for the watchdog.
protection.onDragEvent('dragover')
assert.ok(overlay(dom))
protection.leaveSidebar()
assert.equal(overlay(dom), null, 'native session end must remove the drop target')
assert.equal(dom.pendingTimerCount(), 0, 'native session end must disarm the watchdog')

// 4. A drop in the sidebar clears the target and the watchdog.
dom.emitWindow('dragover', dragEvent())
assert.ok(overlay(dom))
dom.emitWindow('drop', dragEvent({ type: 'drop' }))
assert.equal(overlay(dom), null, 'drop must remove the drop target')
assert.equal(dom.pendingTimerCount(), 0)

// 5. Window blur and Escape abandon the drag as well.
dom.emitWindow('dragover', dragEvent())
dom.emitWindow('blur', { type: 'blur' })
assert.equal(overlay(dom), null, 'blur must remove the drop target')

dom.emitWindow('dragover', dragEvent())
dom.emitWindow('keydown', { type: 'keydown', key: 'Escape' })
assert.equal(overlay(dom), null, 'Escape must remove the drop target')

// 6. Dragging into another part of the page leaves the target too.
dom.emitWindow('dragover', dragEvent())
dom.emitWindow('dragover', dragEvent({ clientX: 900, clientY: 300 }))
assert.equal(overlay(dom), null, 'leaving the sidebar must remove the drop target')

// 7. Cleanup removes listeners and the target; a second teardown is safe.
dom.cleanup()
assert.equal(overlay(dom), null)
assert.equal(dom.document.getElementById(hintId), null)
assert.equal(dom.pendingTimerCount(), 0, 'teardown must disarm the watchdog')
assert.equal(dom.windowListeners.length, 0)
assert.equal(dom.documentListeners.length, 0)

console.log('workspace-drop2add drag fallbacks behave as expected')
