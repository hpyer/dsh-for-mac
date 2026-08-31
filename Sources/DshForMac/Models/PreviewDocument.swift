import Foundation

enum PreviewContentKind: Equatable {
    case image
    case svg
    case markdown
    case text
    case unsupported

    var isPreviewable: Bool {
        self != .unsupported
    }

    static func detect(url: URL, mimeType: String? = nil) -> PreviewContentKind {
        detect(fileName: sourceFileName(for: url), mimeType: mimeType)
    }

    static func detect(fileName: String, mimeType: String? = nil) -> PreviewContentKind {
        let normalizedMimeType = mimeType?.lowercased().split(separator: ";").first.map(String.init)
        if let normalizedMimeType {
            if normalizedMimeType == "image/svg+xml" {
                return .svg
            }
            if normalizedMimeType.hasPrefix("image/") {
                return .image
            }
            if normalizedMimeType == "text/markdown" || normalizedMimeType == "text/x-markdown" {
                return .markdown
            }
            if normalizedMimeType.hasPrefix("text/") || ["application/json", "application/xml", "application/x-yaml", "application/toml"].contains(normalizedMimeType) {
                return .text
            }
        }

        let lowercasedName = fileName.lowercased()
        let fileExtension = URL(fileURLWithPath: lowercasedName).pathExtension

        if ["png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tif", "tiff"].contains(fileExtension) {
            return .image
        }
        if fileExtension == "svg" {
            return .svg
        }
        if ["md", "markdown", "mdown", "mkdn"].contains(fileExtension) {
            return .markdown
        }
        if [
            "txt", "log", "text", "json", "yaml", "yml", "toml", "ini", "conf", "cfg",
            "xml", "html", "htm", "css", "js", "mjs", "cjs", "jsx", "ts", "tsx",
            "swift", "py", "sh", "bash", "zsh", "rb", "php", "go", "rs", "java", "c",
            "h", "cc", "cp", "cpp", "cxx", "hpp", "cs", "kt", "kts", "sql", "vue",
            "svelte", "gradle", "properties", "env", "dockerfile"
        ].contains(fileExtension) || ["dockerfile", "makefile", "rakefile", "gemfile"].contains(lowercasedName) {
            return .text
        }
        return .unsupported
    }

    static func sourceFileName(for url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.lastPathComponent
        }
        let fileNameQueryKeys: Set<String> = ["file", "filename", "name", "path"]
        if let item = components.queryItems?.first(where: {
            fileNameQueryKeys.contains($0.name.lowercased()) && !($0.value ?? "").isEmpty
        }), let value = item.value {
            return URL(fileURLWithPath: value).lastPathComponent
        }
        return url.lastPathComponent
    }
}
