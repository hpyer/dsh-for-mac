# DSH workspace-drop2add experiment

This local DSH Web plugin adds Finder-folder drops to DshForMac's left sidebar.
After the plugin loads, it performs a token-checked handshake with the native
host. The host reads the folder's real path and hands it back to this plugin,
which calls DSH's `workspaces.create({ path })` service.

The experiment only handles drops in the left 438 px of the Web UI, excluding
the bottom 72 px that contains DSH's Settings entry. Drops outside that region
remain DSH's normal attachment flow. If the plugin is disabled or has not
finished loading, the native host does not intercept any drop, so DSH retains
its default behavior.

## Drag-session fallbacks

The "松开鼠标以添加工作区" target is shown while a Finder drag is over the
sidebar, and it must disappear even when the drag never ends there. The native
WebView reports `draggingExited`/`draggingEnded` and clears the target
immediately; the plugin also disarms after 3 seconds without dragenter/dragover
events, and on window blur, page hide, Escape, and leaving the sidebar. This
covers dragging the folder back to Finder, dropping it outside the window,
cancelling with Escape, and a Finder drag that is aborted or never completes.
The plugin-side behavior is covered by `scripts/drag-overlay.test.mjs`.

## Local validation

Install this package into the active DSH `web` profile, restart the DSH Web
service, then drag a Finder folder to the left sidebar. The status pill reports
whether a usable path was received. Outside DshForMac the plugin falls back to
the browser drag payload, which is useful only for diagnostics because WebKit
may expose a directory entry without an absolute path.

Run `pnpm test` from `dsh-plugins/` to execute the contract check and the
drag-session fallback test.

This is deliberately a narrow experiment. It does not yet use a published DSH
sidebar slot for its visual affordance, select the new workspace, or ship as a
public package.
