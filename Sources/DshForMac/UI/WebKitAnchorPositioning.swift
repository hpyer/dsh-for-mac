import Foundation
import WebKit

/// Restores CSS anchor positioning for the floating surfaces DSH added in
/// 0.2.2-rc.5 (menus, model and workspace pickers, popovers). Those surfaces
/// are positioned with `anchor-name`, `position-anchor`, `anchor()`,
/// `anchor-size()` and `@position-try`, which WebKit only implements from
/// macOS 26. On macOS 13-15 every one of them falls back to the top-left or
/// bottom-left corner of the viewport.
///
/// The script is a no-op when the running WebKit supports anchor positioning
/// (including the native macOS 26 path) and when a page contains no anchor
/// positioned CSS, so it is safe to install for every DSH version.
enum WebKitAnchorPositioning {
    static let script: String = AppResourceBundle.string(
        forResource: "anchor-positioning",
        withExtension: "js"
    ) ?? ""

    static func configure(_ controller: WKUserContentController) {
        guard !script.isEmpty else { return }
        controller.addUserScript(WKUserScript(
            source: script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        ))
    }
}
