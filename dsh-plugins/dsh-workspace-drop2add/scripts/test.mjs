import { readFile } from 'node:fs/promises'

const client = await readFile(new URL('../lib/client.js', import.meta.url), 'utf8')

for (const requiredSnippet of [
  "window.__ModuleLoader__.load",
  "ctx.get('workspaces')",
  'workspaces.create({ path })',
  "getData('text/uri-list')",
  'dshWorkspaceDrop2AddBridge',
  '__dshForMacWorkspaceDrop2Add',
  "nativeBridge.postMessage({ action: 'ready', token: bridgeToken })",
  'sidebarFooterHeight = 72',
  'function sidebarRect()',
  "document.querySelector('[role=\"tree\"]')",
  "action: 'sidebar-layout'",
  '__dshForMacWorkspaceDrop2AddProtection',
  "showSidebarDropOverlay(nativeDropProtection.sidebarWidth)",
  "window.dispatchEvent(new Event('dragend'))",
  "setHintVisible(true)",
  "Tips: 拖放文件夹以添加工作区",
  "document.querySelector('div.hHd-Xa_settingsArea')",
  'settingsArea.prepend(node)',
  "padding:8px 20px 0",
  'node.dataset.dshformacWorkspaceDrop2AddHintVersion !== hintStyleVersion',
  'showToast(`已添加工作区：${workspace.title}`)',
  "window.addEventListener('dragover', trackDragLocation, true)"
]) {
  if (!client.includes(requiredSnippet)) {
    throw new Error(`Client bundle is missing ${requiredSnippet}`)
  }
}

console.log('workspace-drop2add client contract is valid')
