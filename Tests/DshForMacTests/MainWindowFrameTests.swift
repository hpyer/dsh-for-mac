import AppKit
import XCTest
@testable import DshForMac

@MainActor
final class MainWindowFrameTests: XCTestCase {
    func testRestoresSavedFrameAfterMoveAndResizeWithToolbar() {
        let autosaveName: NSWindow.FrameAutosaveName = "DshForMacTestMainWindow.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(autosaveName)")
        }

        let targetFrame = NSRect(x: 180, y: 140, width: 960, height: 610)
        do {
            let (window, controller, frameController) = makeMainWindow(autosaveName: autosaveName)
            XCTAssertEqual(window.frameAutosaveName, autosaveName)

            window.setFrame(targetFrame, display: false)
            frameController.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))
            frameController.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))

            controller.windowFrameAutosaveName = ""
            window.close()
        }

        do {
            let (restoredWindow, controller, _) = makeMainWindow(autosaveName: autosaveName)
            defer {
                controller.windowFrameAutosaveName = ""
                restoredWindow.close()
            }
            XCTAssertEqual(restoredWindow.frameAutosaveName, autosaveName)
            XCTAssertEqual(restoredWindow.frame.origin.x, targetFrame.origin.x, accuracy: 1)
            XCTAssertEqual(restoredWindow.frame.origin.y, targetFrame.origin.y, accuracy: 1)
            XCTAssertEqual(restoredWindow.frame.width, targetFrame.width, accuracy: 1)
            XCTAssertEqual(restoredWindow.frame.height, targetFrame.height, accuracy: 1)
        }
    }

    func testDoesNotOverwriteSavedFrameDuringFullScreenTransition() {
        let autosaveName: NSWindow.FrameAutosaveName = "DshForMacTestFullScreen.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(autosaveName)")
        }

        let savedFrame = NSRect(x: 200, y: 160, width: 1_000, height: 640)
        do {
            let (window, controller, frameController) = makeMainWindow(autosaveName: autosaveName)
            window.setFrame(savedFrame, display: false)
            frameController.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))

            frameController.windowWillEnterFullScreen(
                Notification(name: NSWindow.willEnterFullScreenNotification, object: window)
            )
            window.setFrame(NSRect(x: 0, y: 0, width: 1_440, height: 900), display: false)
            frameController.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))

            controller.windowFrameAutosaveName = ""
            window.close()
        }

        do {
            let (restoredWindow, controller, _) = makeMainWindow(autosaveName: autosaveName)
            defer {
                controller.windowFrameAutosaveName = ""
                restoredWindow.close()
            }
            XCTAssertEqual(restoredWindow.frame.origin.x, savedFrame.origin.x, accuracy: 1)
            XCTAssertEqual(restoredWindow.frame.origin.y, savedFrame.origin.y, accuracy: 1)
            XCTAssertEqual(restoredWindow.frame.width, savedFrame.width, accuracy: 1)
            XCTAssertEqual(restoredWindow.frame.height, savedFrame.height, accuracy: 1)
        }
    }

    private func makeMainWindow(
        autosaveName: NSWindow.FrameAutosaveName
    ) -> (NSWindow, NSWindowController, MainWindowFrameController) {
        let initialContentSize = NSSize(width: 1_280, height: 720)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.setContentSize(initialContentSize)
        window.contentMinSize = NSSize(width: 390, height: 360)
        let toolbar = NSToolbar(identifier: "DshForMacTestToolbar")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        let controller = NSWindowController(window: window)
        let frameController = MainWindowFrameController(autosaveName: autosaveName)
        frameController.attach(to: controller)
        return (window, controller, frameController)
    }
}
