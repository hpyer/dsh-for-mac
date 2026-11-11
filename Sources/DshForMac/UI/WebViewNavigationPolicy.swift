import Foundation

/// Classifies navigations requested by the embedded DSH WebView so the
/// container keeps its rule that only the configured local DSH address loads
/// in-app. The value type is WebKit-free so the decisions stay unit tested.
enum WebViewNavigationPolicy {
    /// Where one navigation should go.
    enum Destination: Equatable {
        /// The configured `http://127.0.0.1:<port>` DSH page: load it in-app.
        case localDSH
        /// An empty placeholder window (`about:blank` and friends). DSH's
        /// sign-in flow preopens one and fills it in later, so WebKit must be
        /// allowed to keep it alive instead of prompting for a link.
        case blankPopup
        /// Any other address: leave the app for the system browser/default app.
        case external
    }

    /// DSH's account client calls `window.open("about:blank", "_blank")` on the
    /// user's sign-in click, then navigates that window to the platform
    /// authorize URL once the local server answers. WebKit reports the
    /// placeholder as `about:blank` (older WebKit may report no URL at all), so
    /// both count as a blank popup rather than an external link.
    static func isBlankPopup(_ url: URL?) -> Bool {
        guard let url else { return true }
        return url.scheme?.lowercased() == "about"
    }

    /// DSH listens on a configurable loopback port; everything else, including
    /// `localhost`, the same port on other hosts, and `file:` URLs, is external.
    static func isLocalDSHURL(_ url: URL, port: Int) -> Bool {
        url.scheme == "http" && url.host == "127.0.0.1" && url.port == port
    }

    /// Classifies a navigation the main WebView or a popup asked for.
    static func destination(for url: URL, port: Int) -> Destination {
        if isLocalDSHURL(url, port: port) { return .localDSH }
        if isBlankPopup(url) { return .blankPopup }
        return .external
    }

    /// A blank popup exists only so the page can navigate it later. DSH's first
    /// such navigation is the platform authorize page from the user's sign-in
    /// click, so an HTTP(S) address can go straight to the default browser
    /// without a second confirmation. Non-web schemes still confirm.
    static func canOpenDirectlyInBrowser(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    /// Caps hidden popup WebViews so page content cannot allocate windows
    /// without bound. DSH opens one sign-in popup at a time.
    static let maximumConcurrentPopups = 4

    static func canCreatePopup(existingCount: Int) -> Bool {
        existingCount < maximumConcurrentPopups
    }
}
