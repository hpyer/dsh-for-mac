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

async function scenario(unified) {
  const messages = []
  const opened = []
  let plugin
  const window = {
    __ModuleLoader__: { load(value) { plugin = value.factory() } },
    webkit: { messageHandlers: { dshTaskNotificationBridge: { postMessage(message) { messages.push(message) } } } }
  }
  runInNewContext(source, {
    window,
    crypto: unified
      ? { randomUUID: () => '12345678-1234-4234-8234-123456789abc' }
      : { getRandomValues(bytes) { bytes.fill(7) } },
    setTimeout,
    clearTimeout
  })
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
  const ctx = {
    sessions,
    uiSession: unified ? { sessionStatus: status } : { pendingInteractions: pending },
    uiWorkspace: { openSession(id) { opened.push(id) } }
  }
  const dispose = plugin.apply(ctx)
  assert.equal(messages.length, 1)
  assert.equal(messages[0].kind, 'ready')
  const interaction = { key: 'approval-1', kind: 'approval', sessionId: 'session-1' }
  if (unified) status.set(new Map([['session-1', { running: true, pendingInteraction: interaction, completionUnread: false }]]))
  else pending.set(new Map([['session-1', interaction]]))
  assert.equal(messages.at(-1).kind, 'attention')
  if (unified) status.set(new Map([['session-1', { running: true, pendingInteraction: interaction, completionUnread: false }]]))
  else pending.set(new Map([['session-1', interaction]]))
  assert.equal(messages.filter((message) => message.kind === 'attention').length, 1)
  const childInteraction = { key: 'question-2', kind: 'question', sessionId: 'session-2' }
  if (unified) status.set(new Map([
    ['session-1', { running: true, pendingInteraction: interaction, completionUnread: false }],
    ['session-2', { running: true, pendingInteraction: childInteraction, completionUnread: false }]
  ]))
  else pending.set(new Map([['session-1', interaction], ['session-2', childInteraction]]))
  assert.equal(messages.filter((message) => message.kind === 'attention').length, 2)

  events.set({ entries: [{ event: { type: 'turn/end', seq: 42, data: { reason: { kind: 'completed' } } } }] })
  if (unified) status.set(new Map([['session-1', { running: false, pendingInteraction: undefined, completionUnread: true }]]))
  else {
    pending.set(new Map())
    rows.set({ byId: { 'session-1': { running: false } } })
  }
  await sleep(230)
  assert.equal(messages.at(-1).kind, 'completed')
  if (unified) status.set(new Map([['session-1', { running: true, pendingInteraction: undefined, completionUnread: false }]]))
  else rows.set({ byId: { 'session-1': { running: true } } })
  events.set({ entries: [{ event: { type: 'turn/end', seq: 43, data: { reason: { kind: 'aborted' } } } }] })
  if (unified) status.set(new Map([['session-1', { running: false, pendingInteraction: undefined, completionUnread: true }]]))
  else rows.set({ byId: { 'session-1': { running: false } } })
  await sleep(230)
  assert.equal(messages.filter((message) => message.kind === 'completed').length, 1)
  assert.equal(messages.filter((message) => message.kind === 'ended').length, 0)
  if (unified) status.set(new Map([['session-1', { running: true, pendingInteraction: undefined, completionUnread: false }]]))
  else rows.set({ byId: { 'session-1': { running: true } } })
  events.set({ entries: [] })
  if (unified) status.set(new Map([['session-1', { running: false, pendingInteraction: undefined, completionUnread: true }]]))
  else rows.set({ byId: { 'session-1': { running: false } } })
  await sleep(230)
  assert.equal(messages.at(-1).kind, 'ended')
  window.__dshForMacTaskNotifications.open('session-1')
  window.__dshForMacTaskNotifications.open('session-2')
  assert.deepEqual(opened, ['session-1', { parentSessionId: 'session-1', childSessionId: 'session-2' }])
  dispose()
  assert.equal(window.__dshForMacTaskNotifications, undefined)
}

await scenario(false) // DSH 0.1.5-rc.3
await scenario(true) // DSH 0.1.7-rc.1
console.log('Notification bridge compatibility checks passed')
