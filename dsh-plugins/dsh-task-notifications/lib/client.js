window.__ModuleLoader__.load({
  id: 'dsh-task-notifications',
  factory: () => {
    const module = { exports: {} }
    const exports = module.exports
    const inject = ['sessions', 'uiSession', 'uiWorkspace']

    function createToken() {
      if (typeof crypto.randomUUID === 'function') return crypto.randomUUID()
      const bytes = new Uint8Array(16)
      crypto.getRandomValues(bytes)
      bytes[6] = (bytes[6] & 0x0f) | 0x40
      bytes[8] = (bytes[8] & 0x3f) | 0x80
      const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('')
      return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
    }

    function snapshot(ctx) {
      const rows = ctx.sessions.list.getSnapshot().byId
      const status = new Map()
      // DSH >= 0.1.6-alpha.2: unified status replaces pendingInteractions.
      if (ctx.uiSession.sessionStatus) {
        for (const [sessionId, value] of ctx.uiSession.sessionStatus.getSnapshot()) {
          status.set(sessionId, {
            running: value.running,
            pending: value.pendingInteraction,
            completed: value.completionUnread
          })
        }
      } else {
        // DSH >= 0.1.5-rc.3 and < 0.1.6-alpha.2.
        for (const [sessionId, value] of ctx.uiSession.pendingInteractions.getSnapshot()) {
          status.set(sessionId, { pending: value })
        }
      }
      for (const [sessionId, row] of Object.entries(rows)) {
        const value = status.get(sessionId) ?? {}
        if (value.running === undefined) value.running = row.running
        if (value.completed === undefined) value.completed = row.completed === true
        status.set(sessionId, value)
      }
      return status
    }

    function latestTurnEnd(ctx, sessionId) {
      const entries = ctx.sessions.binding(sessionId)?.eventSource.getSnapshot().entries ?? []
      for (let index = entries.length - 1; index >= 0; index--) {
        const event = entries[index].event
        if (event?.type === 'turn/end') return event
        if (event?.type === 'turn/start') break
      }
      return undefined
    }

    function apply(ctx) {
      const bridge = window.webkit?.messageHandlers?.dshTaskNotificationBridge
      if (!bridge) return
      const token = createToken()
      let previous = snapshot(ctx)
      let sequence = 0
      let notificationSequence = 0
      const sent = new Set()
      const stopTimers = new Set()
      const lastEndSeq = new Map([...previous.keys()].map((id) => [id, latestTurnEnd(ctx, id)?.seq]))
      const post = (kind, sessionId, key) => {
        const identity = `${kind}:${sessionId}:${key}`
        if (sent.has(identity)) return
        sent.add(identity)
        bridge.postMessage({ token, kind, sessionId, key: `${token}:${++notificationSequence}` })
      }
      const changed = () => {
        const next = snapshot(ctx)
        for (const [sessionId, current] of next) {
          const old = previous.get(sessionId) ?? {}
          if (current.pending && current.pending.key !== old.pending?.key &&
              ['approval', 'question', 'plan-review'].includes(current.pending.kind)) {
            post('attention', sessionId, current.pending.key)
          }
          if (old.running !== true && current.running === true) {
            lastEndSeq.set(sessionId, latestTurnEnd(ctx, sessionId)?.seq)
          }
          if (old.running === true && current.running === false && !current.pending) {
            const timer = setTimeout(() => {
              stopTimers.delete(timer)
              const latest = snapshot(ctx).get(sessionId)
              if (!latest || latest.running || latest.pending) return
              const end = latestTurnEnd(ctx, sessionId)
              if (end?.seq !== undefined && end.seq !== lastEndSeq.get(sessionId)) {
                if (end.data?.reason?.kind === 'completed') post('completed', sessionId, String(end.seq))
              } else {
                // An unretained session has no event window. DSH's own
                // completion reminder also follows a running->stopped edge.
                post('ended', sessionId, String(++sequence))
              }
            }, 200)
            stopTimers.add(timer)
          }
        }
        previous = next
      }
      const disposers = [ctx.sessions.list.subscribe(changed)]
      if (ctx.uiSession.sessionStatus) {
        disposers.push(ctx.uiSession.sessionStatus.subscribe(changed))
      } else {
        disposers.push(ctx.uiSession.pendingInteractions.subscribe(changed))
      }
      const open = (sessionId) => {
        if (typeof sessionId !== 'string') return
        const show = () => {
          const address = ctx.sessions.subagentAddress?.(sessionId)
          if (address || ctx.sessions.list.getSnapshot().byId[sessionId]) {
            ctx.uiWorkspace.openSession(address ?? sessionId)
          }
        }
        if (ctx.sessions.list.getSnapshot().byId[sessionId] || ctx.sessions.subagentAddress?.(sessionId)) show()
        else ctx.sessions.refresh().then(show).catch(() => {})
      }
      window.__dshForMacTaskNotifications = { token, open }
      bridge.postMessage({ token, kind: 'ready' })
      return () => {
        for (const timer of stopTimers) clearTimeout(timer)
        for (const dispose of disposers) dispose()
        if (window.__dshForMacTaskNotifications?.token === token) {
          delete window.__dshForMacTaskNotifications
        }
      }
    }

    exports.apply = apply
    exports.inject = inject
    return module.exports
  }
})
