# DshForMac DSH plugins

This pnpm workspace contains DSH plugins developed by this project. They are
kept separate from the native AppKit launcher and are local-only until a plugin
is ready to be published as its own package.

## Commands

```sh
cd dsh-plugins
pnpm check
pnpm test
```

## Local installation

With the DSH CLI available, link one plugin to the Web profile:

```sh
dsh plugin --profile web add ./dsh-plugins/dsh-workspace-drop2add
```

Restart DSH after changing its profile packages. To remove the local link:

```sh
dsh plugin --profile web remove dsh-workspace-drop2add
```

## Current experiments

- [`dsh-workspace-drop2add`](dsh-workspace-drop2add/README.md) pairs with DshForMac's
  token-checked native bridge so a Finder folder dragged onto the left sidebar
  can become a DSH workspace.
