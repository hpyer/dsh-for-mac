import { readFile } from 'node:fs/promises'

const packageJson = JSON.parse(await readFile(new URL('../package.json', import.meta.url)))

if (packageJson.name !== 'dsh-workspace-drop2add') {
  throw new Error('The package must use the dsh-workspace-drop2add name.')
}

if (packageJson.dsh?.bundle?.patch !== './cordis.patch.yml') {
  throw new Error('The package must declare its DSH bundle patch.')
}
if (packageJson.dsh?.client?.platform !== 'web') {
  throw new Error('The package must declare a web DSH client.')
}
if (packageJson.exports?.['./client'] !== './lib/client.js') {
  throw new Error('The package must export its browser client bundle.')
}

console.log('workspace-drop2add manifest is valid')
