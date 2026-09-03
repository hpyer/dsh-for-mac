import AppKit
import WebKit

/// Lets the native host accept Finder folders only after the DSH plugin has
/// registered its bridge. All other drops continue through WKWebView to DSH.
final class WorkspaceDrop2AddWebView: WKWebView {
    var isWorkspaceDrop2AddBridgeReady = false
    var sidebarDrop2AddWidth: CGFloat = 0
    var onWorkspaceDirectoryDropped: ((URL) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let webOperation = super.draggingEntered(sender)
        // Let WebKit continue to receive the drag stream whenever it accepts
        // it. The page-side guard then separates sidebar folders from chat
        // attachments without leaving DSH's overlay state half-open.
        return webOperation == [] && acceptsWorkspaceDirectory(from: sender) ? .copy : webOperation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let webOperation = super.draggingUpdated(sender)
        return webOperation == [] && acceptsWorkspaceDirectory(from: sender) ? .copy : webOperation
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let directoryURL = workspaceDirectoryURL(from: sender) else {
            return super.performDragOperation(sender)
        }
        onWorkspaceDirectoryDropped?(directoryURL)
        return true
    }

    private func acceptsWorkspaceDirectory(from sender: NSDraggingInfo) -> Bool {
        guard isWorkspaceDrop2AddBridgeReady, isSidebarDrop(sender) else { return false }
        return workspaceDirectoryURL(from: sender) != nil
    }

    private func isSidebarDrop(_ sender: NSDraggingInfo) -> Bool {
        let location = convert(sender.draggingLocation, from: nil)
        return location.x >= 0
            && location.x <= sidebarDrop2AddWidth
            && location.y >= 72
    }

    private func workspaceDirectoryURL(from sender: NSDraggingInfo) -> URL? {
        guard isWorkspaceDrop2AddBridgeReady,
              isSidebarDrop(sender),
              let urls = sender.draggingPasteboard.readObjects(
                  forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]
              ) as? [URL],
              urls.count == 1,
              let url = urls.first,
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else {
            return nil
        }
        return url.standardizedFileURL
    }
}
