import AppKit
import WebKit
import XCTest
@testable import DshForMac

/// `draggingEnded:` is an optional `NSDraggingDestination` method that neither
/// `NSView` nor `WKWebView` implements. Responding to it is the only way AppKit
/// delivers it, and there is no superclass implementation to call; a super call
/// raises `unrecognized selector` on the first real drag. These tests keep the
/// override safe.
final class WorkspaceDrop2AddDragSessionTests: XCTestCase {
    func testRespondsToTheOptionalDraggingEndedMessage() {
        XCTAssertTrue(
            WorkspaceDrop2AddWebView.instancesRespond(
                to: #selector(NSDraggingDestination.draggingEnded(_:))
            )
        )
    }

    func testDraggingEndedReportsTheSessionEnd() {
        let webView = WorkspaceDrop2AddWebView(frame: .zero)
        var endedCount = 0
        webView.onWorkspaceDragSessionEnded = { endedCount += 1 }

        webView.draggingEnded(FakeDraggingInfo())

        XCTAssertEqual(endedCount, 1)
    }

    func testDraggingExitedReportsTheSessionEnd() {
        let webView = WorkspaceDrop2AddWebView(frame: .zero)
        var endedCount = 0
        webView.onWorkspaceDragSessionEnded = { endedCount += 1 }

        webView.draggingExited(FakeDraggingInfo())

        XCTAssertEqual(endedCount, 1)
    }
}

private final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { NSPoint(x: 120, y: 200) }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { NSPasteboard(name: NSPasteboard.Name("DshForMacDragSessionTests")) }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var numberOfValidItemsForDrop: Int = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
