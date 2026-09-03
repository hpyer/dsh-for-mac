window.__ModuleLoader__.load({
  id: 'dsh-workspace-drop2add',
  factory: () => {
    const module = { exports: {} }
    const exports = module.exports
    const sidebarFooterHeight = 72
    const hintId = 'dsh-workspace-drop2add-hint'
    const hintStyleVersion = 'settings-area-v1'
    const overlayId = 'dsh-workspace-drop2add-overlay'
    const toastId = 'dsh-workspace-drop2add-toast'
    let toastTimer

    function workspacePathFrom(dataTransfer) {
      const uriList = dataTransfer.getData('text/uri-list')
      for (const candidate of uriList.split(/\r?\n/)) {
        const value = candidate.trim()
        if (!value || value.startsWith('#')) continue
        try {
          const url = new URL(value)
          if (url.protocol === 'file:') return decodeURIComponent(url.pathname)
        } catch {
          // A diagnostic below explains that the WebView did not expose a URL.
        }
      }
      return undefined
    }

    function dataTransferSummary(dataTransfer) {
      const types = Array.from(dataTransfer.types ?? [])
      const entries = Array.from(dataTransfer.items ?? []).map((item) => {
        const entry = item.webkitGetAsEntry?.()
        if (entry?.isDirectory) return 'directory'
        if (entry?.isFile) return 'file'
        return item.kind || 'unknown'
      })
      return { types, entries }
    }

    function sidebarRect() {
      const toggle = Array.from(document.querySelectorAll('button')).find((button) => {
        const label = button.getAttribute('aria-label') || button.getAttribute('title') || ''
        return label.includes('展开侧边栏') || label.includes('Expand sidebar')
      })
      if (toggle) return { left: 0, width: 0, right: 0 }

      const fromSidebarChild = (start) => {
        let node = start
        while (node && node !== document.body) {
          const rect = node.getBoundingClientRect()
          if (rect.left <= 1 && rect.top <= 1 && rect.height >= window.innerHeight * 0.7 && rect.width >= 40 && rect.width < window.innerWidth * 0.7) {
            return rect
          }
          node = node.parentElement
        }
        return undefined
      }

      const workspaceTree = document.querySelector('[role="tree"]')
      const treeRect = workspaceTree ? fromSidebarChild(workspaceTree) : undefined
      if (treeRect) return treeRect

      let element = document.elementFromPoint(1, Math.min(window.innerHeight / 2, 240))
      return element ? fromSidebarChild(element) : undefined
    }

    function isSidebarDrop(event) {
      const rect = sidebarRect()
      return rect
        && rect.width >= 120
        && event.clientX >= rect.left
        && event.clientX <= rect.right
        && event.clientY <= window.innerHeight - sidebarFooterHeight
    }

    function ensureHint() {
      let node = document.getElementById(hintId)
      if (!node) {
        node = document.createElement('div')
        node.id = hintId
      }
      // Reset styles from a hot-reloaded earlier plugin version once. Do not
      // write the style attribute on every layout observation: that would
      // trigger the sidebar MutationObserver again indefinitely.
      if (node.dataset.dshformacWorkspaceDrop2AddHintVersion !== hintStyleVersion) {
        node.style.cssText = [
          'display:block',
          'padding:8px 20px 0',
          'box-sizing:border-box',
          'font:14px -apple-system, BlinkMacSystemFont, sans-serif',
          'line-height:20px',
          'color:rgba(107,114,128,.8)',
          'pointer-events:none'
        ].join(';')
        node.dataset.dshformacWorkspaceDrop2AddHintVersion = hintStyleVersion
      }
      const settingsArea = document.querySelector('div.hHd-Xa_settingsArea')
      if (settingsArea && node.parentElement !== settingsArea) {
        // Keep the hint inside DSH's own footer so it reserves real layout
        // space instead of floating above the sidebar scroll container.
        settingsArea.prepend(node)
      } else if (!node.parentElement) {
        // Compatibility fallback for a future DSH DOM class rename.
        document.body.append(node)
      }
      if (node.textContent !== 'Tips: 拖放文件夹以添加工作区') {
        node.textContent = 'Tips: 拖放文件夹以添加工作区'
      }
      return node
    }

    function setHintVisible(visible) {
      const node = ensureHint()
      const display = visible ? 'block' : 'none'
      if (node.style.display !== display) node.style.display = display
    }

    function showSidebarDropOverlay(width) {
      let node = document.getElementById(overlayId)
      if (!node) {
        node = document.createElement('div')
        node.id = overlayId
        node.setAttribute('role', 'status')
        node.style.cssText = [
          'position:fixed',
          'z-index:2147483646',
          'top:0',
          'bottom:0',
          'left:0',
          'display:flex',
          'align-items:center',
          'justify-content:center',
          'box-sizing:border-box',
          'padding:28px 18px',
          'background:rgba(255,255,255,.64)',
          'backdrop-filter:blur(12px)',
          '-webkit-backdrop-filter:blur(12px)',
          'pointer-events:none',
          'transition:opacity .14s ease, background .14s ease'
        ].join(';')
        const content = document.createElement('div')
        content.style.cssText = [
          'display:flex',
          'flex-direction:column',
          'align-items:center',
          'gap:14px',
          'text-align:center',
          'color:#17191d',
          'font:600 18px -apple-system, BlinkMacSystemFont, sans-serif',
          'line-height:26px',
          'letter-spacing:.01em'
        ].join(';')
        const icon = document.createElementNS('http://www.w3.org/2000/svg', 'svg')
        icon.setAttribute('viewBox', '0 0 80 64')
        icon.setAttribute('width', '80')
        icon.setAttribute('height', '64')
        icon.setAttribute('aria-hidden', 'true')
        icon.innerHTML = '<path d="M7 18.5c0-4.7 3.8-8.5 8.5-8.5h18l6.8 8H64.5c4.7 0 8.5 3.8 8.5 8.5v21C73 52.2 69.2 56 64.5 56h-49C10.8 56 7 52.2 7 47.5v-29Z" fill="#4f82ff"/><path d="M7 27h66v20.5c0 4.7-3.8 8.5-8.5 8.5h-49C10.8 56 7 52.2 7 47.5V27Z" fill="#3268e6"/><path d="M21 38h38" stroke="white" stroke-width="4" stroke-linecap="round"/>'
        const label = document.createElement('div')
        label.textContent = '松开鼠标以添加工作区'
        content.append(icon, label)
        node.append(content)
        document.body.append(node)
      }
      node.style.width = `${Math.max(0, width)}px`
      node.style.display = 'flex'
    }

    function hideSidebarDropOverlay() {
      document.getElementById(overlayId)?.remove()
    }

    function showToast(text, tone = 'success') {
      document.getElementById(toastId)?.remove()
      const node = document.createElement('div')
      node.id = toastId
      node.setAttribute('role', 'status')
      const colors = tone === 'error'
        ? ['rgba(185,28,28,.96)', '#fff']
        : ['rgba(17,24,39,.90)', '#fff']
      node.style.cssText = [
        'position:fixed',
        'z-index:2147483647',
        'left:50%',
        'bottom:32px',
        'transform:translateX(-50%)',
        'max-width:min(420px, calc(100vw - 48px))',
        'padding:10px 14px',
        'border-radius:9px',
        `background:${colors[0]}`,
        `color:${colors[1]}`,
        'box-shadow:0 8px 24px rgba(0,0,0,.18)',
        'font:14px -apple-system, BlinkMacSystemFont, sans-serif',
        'line-height:20px',
        'pointer-events:none'
      ].join(';')
      node.textContent = text
      document.body.append(node)
      clearTimeout(toastTimer)
      toastTimer = window.setTimeout(() => node.remove(), tone === 'error' ? 4_000 : 2_400)
    }

    const inject = ['workspaces']

    function createBridgeToken() {
      if (typeof crypto.randomUUID === 'function') return crypto.randomUUID()
      const bytes = new Uint8Array(16)
      crypto.getRandomValues(bytes)
      bytes[6] = (bytes[6] & 0x0f) | 0x40
      bytes[8] = (bytes[8] & 0x3f) | 0x80
      const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('')
      return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
    }

    function apply(ctx) {
      const workspaces = ctx.get('workspaces')
      const nativeBridge = window.webkit?.messageHandlers?.dshWorkspaceDrop2AddBridge
      const bridgeToken = createBridgeToken()
      let layoutRefreshScheduled = false
      const nativeDropProtection = {
        enabled: Boolean(nativeBridge),
        sidebarWidth: 0,
        isOverSidebar: false,
        clearDSHAttachmentOverlay() {
          // DSH owns this overlay globally. When a Finder drag crosses into
          // the sidebar, it will not receive the eventual drop, so finish its
          // drag lifecycle before presenting the workspace target.
          window.dispatchEvent(new Event('dragend'))
        },
        enterSidebar() {
          if (!nativeDropProtection.isOverSidebar) {
            nativeDropProtection.clearDSHAttachmentOverlay()
            nativeDropProtection.isOverSidebar = true
          }
          setHintVisible(false)
          showSidebarDropOverlay(nativeDropProtection.sidebarWidth)
        },
        leaveSidebar() {
          if (!nativeDropProtection.isOverSidebar) return
          nativeDropProtection.isOverSidebar = false
          hideSidebarDropOverlay()
          setHintVisible(true)
        },
        onDragEvent: (type) => {
          if (type === 'dragenter' || type === 'dragover') {
            nativeDropProtection.enterSidebar()
          } else if (type === 'drop') {
            nativeDropProtection.leaveSidebar()
          }
        }
      }

      const updateSidebarLayout = () => {
        layoutRefreshScheduled = false
        const rect = sidebarRect()
        const isExpanded = Boolean(rect && rect.width >= 120)
        ensureHint()
        setHintVisible(isExpanded && !nativeDropProtection.isOverSidebar)
        if (!isExpanded) hideSidebarDropOverlay()
        nativeDropProtection.sidebarWidth = isExpanded ? rect.width : 0
        if (nativeBridge) {
          nativeBridge.postMessage({
            action: 'sidebar-layout',
            token: bridgeToken,
            width: isExpanded ? rect.width : 0
          })
        }
      }

      const scheduleSidebarLayoutRefresh = () => {
        if (layoutRefreshScheduled) return
        layoutRefreshScheduled = true
        window.requestAnimationFrame(updateSidebarLayout)
      }

      const createWorkspace = async (path) => {
        nativeDropProtection.leaveSidebar()
        try {
          const workspace = await workspaces.create({ path })
          showToast(`已添加工作区：${workspace.title}`)
          console.info('[dsh-workspace-drop2add] Workspace created', {
            workspaceId: workspace.workspaceId,
            title: workspace.title
          })
        } catch (error) {
          console.error('[dsh-workspace-drop2add] Workspace creation failed', error)
          showToast('添加工作区失败，请查看控制台错误', 'error')
        }
      }

      const receiveNativeDrop = (payload) => {
        if (payload?.token !== bridgeToken || typeof payload?.path !== 'string' || !payload.path.startsWith('/')) {
          return
        }
        // DSH's attachment component resets its global drop overlay on dragend.
        // Native directory drops bypass WebKit's normal completion event.
        window.dispatchEvent(new Event('dragend'))
        void createWorkspace(payload.path)
      }

      const entered = (event) => {
        if (!isSidebarDrop(event)) return
        nativeDropProtection.enterSidebar()
      }
      const left = (event) => {
        if (isSidebarDrop(event)) return
        nativeDropProtection.leaveSidebar()
      }
      const over = (event) => {
        if (!isSidebarDrop(event)) return
        event.preventDefault()
        event.dataTransfer.dropEffect = 'copy'
      }
      const dropped = async (event) => {
        if (!isSidebarDrop(event)) return
        event.preventDefault()
        event.stopPropagation()
        nativeDropProtection.leaveSidebar()

        const path = workspacePathFrom(event.dataTransfer)
        const summary = dataTransferSummary(event.dataTransfer)
        console.info('[dsh-workspace-drop2add] Finder drop payload', summary)
        if (!path) {
          const types = summary.types.join(', ') || '无类型'
          const entries = summary.entries.join(', ') || '无条目'
          showToast(`未取得目录路径（types: ${types}; entries: ${entries}）`, 'error')
          return
        }

        await createWorkspace(path)
      }

      if (nativeBridge) {
        window.__dshForMacWorkspaceDrop2Add = { receive: receiveNativeDrop }
        window.__dshForMacWorkspaceDrop2AddProtection = nativeDropProtection
        nativeBridge.postMessage({ action: 'ready', token: bridgeToken })
      } else {
        document.addEventListener('dragenter', entered, true)
        document.addEventListener('dragleave', left, true)
        document.addEventListener('dragover', over, true)
        document.addEventListener('drop', dropped, true)
      }
      setHintVisible(true)
      updateSidebarLayout()
      // The native left-sidebar guard consumes sidebar events before they reach
      // DSH. This second tracker receives the unconsumed right-side events and
      // makes zone transitions reset cleanly in both directions.
      const trackDragLocation = (event) => {
        if (!Array.from(event.dataTransfer?.types ?? []).includes('Files')) return
        if (isSidebarDrop(event)) {
          nativeDropProtection.enterSidebar()
        } else {
          nativeDropProtection.leaveSidebar()
        }
      }
      const finishDrag = () => nativeDropProtection.leaveSidebar()
      window.addEventListener('dragenter', trackDragLocation, true)
      window.addEventListener('dragover', trackDragLocation, true)
      window.addEventListener('drop', finishDrag, true)
      window.addEventListener('dragend', finishDrag, true)
      window.addEventListener('resize', scheduleSidebarLayoutRefresh)
      const sidebarObserver = new MutationObserver(scheduleSidebarLayoutRefresh)
      sidebarObserver.observe(document.body, {
        attributes: true,
        subtree: true,
        attributeFilter: ['class', 'style', 'data-state']
      })

      return () => {
        document.removeEventListener('dragenter', entered, true)
        document.removeEventListener('dragleave', left, true)
        document.removeEventListener('dragover', over, true)
        document.removeEventListener('drop', dropped, true)
        window.removeEventListener('dragenter', trackDragLocation, true)
        window.removeEventListener('dragover', trackDragLocation, true)
        window.removeEventListener('drop', finishDrag, true)
        window.removeEventListener('dragend', finishDrag, true)
        window.removeEventListener('resize', scheduleSidebarLayoutRefresh)
        sidebarObserver.disconnect()
        clearTimeout(toastTimer)
        if (window.__dshForMacWorkspaceDrop2Add?.receive === receiveNativeDrop) {
          delete window.__dshForMacWorkspaceDrop2Add
        }
        if (window.__dshForMacWorkspaceDrop2AddProtection === nativeDropProtection) {
          delete window.__dshForMacWorkspaceDrop2AddProtection
        }
        document.getElementById(hintId)?.remove()
        hideSidebarDropOverlay()
        document.getElementById(toastId)?.remove()
      }
    }

    exports.apply = apply
    exports.inject = inject
    return module.exports
  }
})
