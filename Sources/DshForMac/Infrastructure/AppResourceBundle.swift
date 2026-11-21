import Foundation

private final class AppResourceBundleMarker: NSObject {}

/// Resolves SwiftPM resources both in a `swift run` build and in the packaged
/// application.
///
/// SwiftPM generates a `Bundle.module` accessor that only checks the executable
/// directory and the build machine's `.build` path. A packaged app keeps its
/// resources in `Contents/Resources`, so `Bundle.module` traps with
/// `fatalError` there. This resolver checks the app's resource directory first,
/// then the executable directory, then the parent of an `.xctest` bundle.
enum AppResourceBundle {
    static let bundleName = "DshForMac_DshForMac"

    static func url(forResource name: String, withExtension ext: String) -> URL? {
        let bundles = [
            Bundle.main,
            Bundle(for: AppResourceBundleMarker.self),
        ]
        for bundle in bundles {
            if let url = url(
                forResource: name,
                withExtension: ext,
                resourceURL: bundle.resourceURL,
                bundleURL: bundle.bundleURL
            ) {
                return url
            }
        }
        return nil
    }

    static func url(
        forResource name: String,
        withExtension ext: String,
        resourceURL: URL?,
        bundleURL: URL
    ) -> URL? {
        for bundle in candidateBundles(resourceURL: resourceURL, bundleURL: bundleURL) {
            if let url = bundle.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        return nil
    }

    static func string(forResource name: String, withExtension ext: String) -> String? {
        guard let url = url(forResource: name, withExtension: ext) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func candidateBundles(resourceURL: URL?, bundleURL: URL) -> [Bundle] {
        var candidates: [URL] = []
        if let resourceURL {
            candidates.append(resourceURL.appendingPathComponent("\(bundleName).bundle", isDirectory: true))
        }
        candidates.append(bundleURL.appendingPathComponent("\(bundleName).bundle", isDirectory: true))
        candidates.append(bundleURL.deletingLastPathComponent()
            .appendingPathComponent("\(bundleName).bundle", isDirectory: true))
        candidates.append(bundleURL
            .appendingPathComponent("Contents/Resources/\(bundleName).bundle", isDirectory: true))

        var seen = Set<String>()
        return candidates.compactMap { url in
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return nil }
            return Bundle(url: url)
        }
    }
}
