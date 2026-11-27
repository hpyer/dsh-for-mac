import AppKit

/// Persists and restores the main window's frame across launches without
/// allowing toolbar setup, NSWindowController creation, or full-screen
/// transitions to clobber the saved size and position.
@MainActor
final class MainWindowFrameController: NSObject, NSWindowDelegate {
    nonisolated static let defaultAutosaveName: NSWindow.FrameAutosaveName = "DshForMacMainWindow"

    private let autosaveName: NSWindow.FrameAutosaveName
    private weak var windowController: NSWindowController?
    private weak var window: NSWindow?
    private var isRestoringFrame = false
    private var isInFullScreenTransition = false

    init(autosaveName: NSWindow.FrameAutosaveName = MainWindowFrameController.defaultAutosaveName) {
        self.autosaveName = autosaveName
        super.init()
    }

    func attach(to windowController: NSWindowController, screens: [NSScreen] = NSScreen.screens) {
        guard let window = windowController.window else { return }
        self.windowController = windowController
        self.window = window
        windowController.shouldCascadeWindows = false
        window.delegate = self

        isRestoringFrame = true
        defer { isRestoringFrame = false }

        let hadSavedFrame = window.setFrameUsingName(autosaveName)
        if !hadSavedFrame || (!screens.isEmpty && !Self.isFrameVisible(window.frame, on: screens)) {
            window.center()
        }
        windowController.windowFrameAutosaveName = autosaveName
    }

    func saveCurrentFrame() {
        guard !isRestoringFrame, !isInFullScreenTransition, let window, !window.styleMask.contains(.fullScreen) else {
            return
        }
        window.saveFrame(usingName: autosaveName)
    }

    func windowDidMove(_ notification: Notification) {
        saveCurrentFrame()
    }

    func windowDidResize(_ notification: Notification) {
        saveCurrentFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveCurrentFrame()
    }

    func windowWillClose(_ notification: Notification) {
        saveCurrentFrame()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        saveCurrentFrame()
        isInFullScreenTransition = true
        // Pause AppKit's automatic frame persistence while in full screen so
        // full-screen bounds cannot overwrite the normal desktop frame.
        windowController?.windowFrameAutosaveName = ""
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        isInFullScreenTransition = false
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        isInFullScreenTransition = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        isInFullScreenTransition = false
        saveCurrentFrame()
        windowController?.windowFrameAutosaveName = autosaveName
    }

    static func isFrameVisible(_ frame: NSRect, on screens: [NSScreen]) -> Bool {
        screens.contains { screen in
            let visibleArea = screen.visibleFrame.intersection(frame)
            return visibleArea.width >= 200 && visibleArea.height >= 120
        }
    }
}
