import Foundation

struct NodeRuntimeDetector {
    private let fileManager: FileManager
    private let commandRunner: any CommandRunning
    private let environment: [String: String]

    init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunning = ProcessCommandRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.commandRunner = commandRunner
        self.environment = environment
    }

    func detect(preferredNodeURL: URL? = nil) -> NodeRuntimeStatus {
        guard let nodeURL = findNode(preferredNodeURL: preferredNodeURL) else {
            return .notFound
        }

        do {
            let versionResult = try commandRunner.run(
                executableURL: nodeURL,
                arguments: ["--version"],
                environment: environment
            )
            guard versionResult.exitCode == 0,
                  let version = SemanticVersion(string: versionResult.standardOutput)
            else {
                return .failed("无法读取 Node.js 版本：\(versionResult.standardError.trimmingCharacters(in: .whitespacesAndNewlines))")
            }

            let architectureResult = try commandRunner.run(
                executableURL: nodeURL,
                arguments: ["-p", "process.arch"],
                environment: environment
            )
            let architecture = architectureResult.exitCode == 0
                ? architectureResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                : "unknown"

            let runtime = NodeRuntime(
                nodeURL: nodeURL,
                npmURL: findSiblingExecutable(named: "npm", beside: nodeURL),
                pnpmURL: findPnpmExecutable(beside: nodeURL),
                corepackURL: findSiblingExecutable(named: "corepack", beside: nodeURL),
                npxURL: findSiblingExecutable(named: "npx", beside: nodeURL),
                version: version,
                architecture: architecture
            )

            guard runtime.supportsDSH else { return .unsupported(runtime) }
            guard runtime.npmURL != nil else { return .missingNpm(runtime) }
            guard runtime.npxURL != nil else { return .missingNpx(runtime) }
            return .ready(runtime)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func findNode(preferredNodeURL: URL?) -> URL? {
        let candidates = [preferredNodeURL].compactMap { $0 } + pathCandidates(named: "node") + [
            URL(fileURLWithPath: "/opt/homebrew/bin/node"),
            URL(fileURLWithPath: "/usr/local/bin/node"),
        ] + managedNodeCandidates()
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func findSiblingExecutable(named name: String, beside nodeURL: URL) -> URL? {
        let sibling = nodeURL.deletingLastPathComponent().appendingPathComponent(name)
        if fileManager.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        return pathCandidates(named: name).first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func findPnpmExecutable(beside nodeURL: URL) -> URL? {
        if let pnpmURL = findSiblingExecutable(named: "pnpm", beside: nodeURL) {
            return pnpmURL
        }

        return Self.commonPnpmCandidates(homeDirectory: fileManager.homeDirectoryForCurrentUser)
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    static func commonPnpmCandidates(homeDirectory: URL) -> [URL] {
        [
            homeDirectory.appendingPathComponent("Library/pnpm/pnpm"),
            homeDirectory.appendingPathComponent(".local/share/pnpm/pnpm"),
            homeDirectory.appendingPathComponent(".volta/bin/pnpm"),
            homeDirectory.appendingPathComponent(".mise/shims/pnpm"),
            homeDirectory.appendingPathComponent(".asdf/shims/pnpm"),
            URL(fileURLWithPath: "/opt/homebrew/bin/pnpm"),
            URL(fileURLWithPath: "/usr/local/bin/pnpm"),
        ]
    }

    private func pathCandidates(named executable: String) -> [URL] {
        let path = environment["PATH"] ?? ""
        return path.split(separator: ":").map {
            URL(fileURLWithPath: String($0)).appendingPathComponent(executable)
        }
    }

    private func managedNodeCandidates() -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        let fixedCandidates = [
            home.appendingPathComponent(".volta/bin/node"),
            home.appendingPathComponent(".mise/shims/node"),
            home.appendingPathComponent(".asdf/shims/node"),
        ]
        let versionedCandidates = [
            home.appendingPathComponent(".nvm/versions/node"),
            home.appendingPathComponent(".fnm/node-versions"),
            home.appendingPathComponent(".local/share/fnm/node-versions"),
            home.appendingPathComponent(".local/state/fnm_multishells"),
            home.appendingPathComponent(".asdf/installs/nodejs"),
            home.appendingPathComponent(".mise/installs/node"),
        ].flatMap { versionedNodes(in: $0) }

        return fixedCandidates + versionedCandidates
    }

    private func versionedNodes(in directory: URL) -> [URL] {
        guard let versions = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return versions
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            .flatMap { versionDirectory in
                [
                    versionDirectory.appendingPathComponent("bin/node"),
                    versionDirectory.appendingPathComponent("installation/bin/node"),
                ]
            }
    }
}
