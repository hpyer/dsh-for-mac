import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { runInNewContext } from 'node:vm'
import { setTimeout as sleep } from 'node:timers/promises'

const source = readFileSync(new URL('../lib/client.js', import.meta.url), 'utf8')

function store(initial) {
  let value = initial
  const listeners = new Set()
  return {
    getSnapshot: () => value,
    subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener) },
    set(next) { value = next; for (const listener of listeners) listener() }
  }
}

// DSH releases expose the session status differently:
// - pending: 0.1.5-rc.3, only uiSession.pendingInteractions
// - property: 0.1.6-alpha.2 .. 0.2.2, uiSession.sessionStatus is a plain property
// - service: 0.2.3-alpha.1+, uiSession.sessionStatus is a separate service that
//   throws `cannot get property "uiSession.sessionStatus" without inject` when
//   read as a property without injection.
// - service-inactive: the service is declared but not active yet, so both the
//   service and the property are unreadable; pendingInteractions must carry it.
async function scenario(mode) {
  const usesStatus = mode === 'property' || mode === 'service'
  const messages = []
  const opened = []
  let plugin
  const window = {
    __ModuleLoader__: { load(value) { plugin = value.factory() } },
    webkit: { messageHandlers: { dshTaskNotificationBridge: { postMessage(message) { messages.push(message) } } } }
  }
  // Keep both token paths covered: WebKit without crypto.randomUUID falls back
  // to getRandomValues, and the native side requires a UUID either way.
  const crypto = mode === 'pending'
    ? { getRandomValues(bytes) { bytes.fill(7) } }
    : { randomUUID: () => '12345678-1234-4234-8234-123456789abc' }
  runInNewContext(source, { window, crypto, setTimeout, clearTimeout })
  const rows = store({ byId: { 'session-1': { running: true } } })
  const pending = store(new Map())
  const status = store(new Map([['session-1', { running: true, pendingInteraction: undefined, completionUnread: false }]]))
  const events = store({ entries: [] })
  const sessions = {
    list: rows,
    binding: () => ({ eventSource: events }),
    subagentAddress: (id) => id === 'session-2' ? { parentSessionId: 'session-1', childSessionId: id } : undefined,
    refresh: async () => {}
  }
  const uiSession = {}
  if (mode === 'pending' || mode === 'service-inactive') uiSession.pendingInteractions = pending
  if (mode === 'property') uiSession.sessionStatus = status
  if (mode === 'service' || mode === 'service-inactive') {
    Object.defineProperty(uiSession, 'sessionStatus', {
      get() { throw new Error('cannot get property "uiSession.sessionStatus" without inject') }
    })
  }
  const ctx = {
    sessions,
    uiSession,
    uiWorkspace: { openSession(id) { opened.push(id) } }
  }
  if (mode === 'service' || mode === 'service-inactive') {
    ctx.get = (name) => name === 'uiSession.sessionStatus' && mode === 'service' ? status : undefined
  }

  const setRunning = (running) => {
    if (usesStatus) status.set(new Map([['session-1', { running, pendingInteraction: undefined, completionUnread: false }]]))
    else {
      // A turn cannot end while an interaction is pending.
      pending.set(new Map())
      rows.set({ byId: { 'session-1': { running } } })
    }
  }
  const setPending = (sessionId, interaction) => {
    if (usesStatus) {
      const entries = new Map(status.getSnapshot())
      entries.set(sessionId, { running: true, pendingInteraction: interaction, completionUnread: false })
      status.set(entries)
    } else {
      const entries = new Map(pending.getSnapshot())
      entries.set(sessionId, interaction)
      pending.set(entries)
    }
  }

  const dispose = plugin.apply(ctx)
  assert.equal(messages.length, 1)
  assert.equal(messages[0].kind, 'ready')
  assert.match(messages[0].token, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)

  const interaction = { key: 'approval-1', kind: 'approval', sessionId: 'session-1' }
  setPending('session-1', interaction)
  assert.equal(messages.at(-1).kind, 'attention')
  setPending('session-1', interaction)
  assert.equal(messages.filter((message) => message.kind === 'attention').length, 1)

  const childInteraction = { key: 'question-2', kind: 'question', sessionId: 'session-2' }
  setPending('session-2', childInteraction)
  assert.equal(messages.filter((message) => message.kind === 'attention').length, 2)

  events.set({ entries: [{ event: { type: 'turn/end', seq: 42, data: { reason: { kind: 'completed' } } } }] })
  setRunning(false)
  await sleep(230)
  assert.equal(messages.at(-1).kind, 'completed')

  setRunning(true)
  events.set({ entries: [{ event: { type: 'turn/end', seq: 43, data: { reason: { kind: 'aborted' } } } }] })
  setRunning(false)
  await sleep(230)
  assert.equal(messages.filter((message) => message.kind === 'completed').length, 1)
  assert.equal(messages.filter((message) => message.kind === 'ended').length, 0)

  setRunning(true)
  events.set({ entries: [] })
  setRunning(false)
  await sleep(230)
  assert.equal(messages.at(-1).kind, 'ended')

  window.__dshForMacTaskNotifications.open('session-1')
  window.__dshForMacTaskNotifications.open('session-2')
  assert.deepEqual(opened, ['session-1', { parentSessionId: 'session-1', childSessionId: 'session-2' }])
  dispose()
  assert.equal(window.__dshForMacTaskNotifications, undefined)
}

await scenario('pending') // DSH 0.1.5-rc.3
await scenario('property') // DSH 0.1.6-alpha.2 .. 0.2.2
await scenario('service') // DSH 0.2.3-alpha.2
await scenario('service-inactive') // 0.2.3 service declared but not readable yet
console.log('Notification bridge compatibility checks passed')
