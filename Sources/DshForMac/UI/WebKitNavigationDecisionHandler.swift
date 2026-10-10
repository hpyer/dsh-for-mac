import WebKit

// WebKit's Swift imports gained actor/sendability annotations in newer SDKs.
// Match each toolchain's optional WKNavigationDelegate requirement exactly.
#if compiler(>=6.0)
typealias NavigationActionDecisionHandler = @MainActor @Sendable (WKNavigationActionPolicy) -> Void
#else
typealias NavigationActionDecisionHandler = (WKNavigationActionPolicy) -> Void
#endif
