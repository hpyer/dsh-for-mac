import Foundation

enum SystemSearchPath {
    /// Read path_helper's configuration without launching a shell or sourcing rc files.
    static func directories(
        pathsFile: URL = URL(fileURLWithPath: "/etc/paths"),
        pathsDirectory: URL = URL(fileURLWithPath: "/etc/paths.d")
    ) -> [String] {
        let extraFiles = (try? FileManager.default.contentsOfDirectory(
            at: pathsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        let files = [pathsFile] + extraFiles.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return files.flatMap { file -> [String] in
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return [] }
            return contents.components(separatedBy: .newlines).compactMap { line in
                let path = line.trimmingCharacters(in: .whitespaces)
                // Ignore malformed entries rather than accidentally adding the current directory.
                guard path.hasPrefix("/"), !path.contains(":"), !path.contains("\0") else { return nil }
                return path
            }
        }
    }
}
