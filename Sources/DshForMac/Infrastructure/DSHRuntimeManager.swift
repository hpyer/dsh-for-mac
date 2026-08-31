import Foundation
import Darwin

struct DSHRelease: Decodable, Sendable {
    let version: String
    let integrity: String

    enum CodingKeys: String, CodingKey {
        case version
        case integrity = "dist.integrity"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        version = try container.decode(String.self, forKey: DynamicCodingKey("version"))

        if let dist = try? container.decode(Distribution.self, forKey: DynamicCodingKey("dist")) {
            integrity = dist.integrity
        } else {
            integrity = try container.decode(String.self, forKey: DynamicCodingKey("dist.integrity"))
        }
    }

    private struct Distribution: Decodable, Sendable {
        let integrity: String
    }
}

struct DSHStartupResult: Sendable {
    let address: URL
    let version: String
}

enum DSHUpdateCheckResult: Sendable {
    case downloaded(String)
    case alreadyInstalled(String)

    var version: String {
        switch self {
        case let .downloaded(version), let .alreadyInstalled(version): version
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        return nil
    }
}

enum DSHRuntimeError: LocalizedError {
    case npmUnavailable
    case metadataInvalid
    case installFailed(String)
    case integrityMismatch
    case executableMissing
    case selectedVersionUnavailable(String)
    case portInUse(Int)
    case startupTimedOut(String)

    var errorDescription: String? {
        switch self {
        case .npmUnavailable:
            "未找到可用的 npm，无法安装 DSH。"
        case .metadataInvalid:
            "无法从 npm registry 解析 DSH 的版本信息。"
        case let .installFailed(detail):
            "DSH 安装失败。\(detail)"
        case .integrityMismatch:
            "已安装包的完整性校验失败，未启动 DSH。"
        case .executableMissing:
            "安装完成后未找到 DSH 可执行文件。"
        case let .selectedVersionUnavailable(version):
            "所选 DSH 版本 \(version) 不可用。请选择另一个已安装版本。"
        case let .startupTimedOut(log):
            "DSH 启动超时。\(log)"
        case let .portInUse(port):
            "本机端口 \(port) 已被其他服务占用。请先停止该服务，或在设置中选择其他端口。"
        }
    }
}

@MainActor
final class DSHRuntimeManager {
    static let defaultRegistry = PackageRegistry.tencent.url
    static let defaultPort = 30_80

    private let fileManager: FileManager
    private let statusHandler: (String) -> Void
    private var dshProcess: Process?
    private var managedServerPID: pid_t?
    private var expectedProcessTerminations = Set<pid_t>()
    private var recentOutput = ""

    private enum PackageManager {
        case pnpm(URL)
        case npm(URL)

        var executableURL: URL {
            switch self {
            case let .pnpm(url), let .npm(url):
                url
            }
        }

        var installArguments: [String] {
            switch self {
            case .pnpm:
                ["install", "--prod", "--no-frozen-lockfile"]
            case .npm:
                ["install", "--omit=dev", "--no-audit", "--no-fund"]
            }
        }

        var displayName: String {
            switch self {
            case .pnpm: "pnpm"
            case .npm: "npm"
            }
        }
    }

    init(
        fileManager: FileManager = .default,
        statusHandler: @escaping (String) -> Void
    ) {
        self.fileManager = fileManager
        self.statusHandler = statusHandler
    }

    func start(using runtime: NodeRuntime) async throws -> DSHStartupResult {
        let rootDirectory = try applicationSupportDirectory()
        let versionsDirectory = runtimeVersionsDirectory(in: rootDirectory)
        let environment = processEnvironment(for: runtime)
        let port = AppSettings.shared.port

        if let selectedVersion = AppSettings.shared.selectedRuntimeVersion {
            return try await startInstalledRuntime(
                version: selectedVersion,
                in: versionsDirectory,
                rootDirectory: rootDirectory,
                nodeURL: runtime.nodeURL,
                port: port,
                environment: environment
            )
        }

        if let currentVersion = currentRuntimeVersion(in: rootDirectory) {
            return try await startInstalledRuntime(
                version: currentVersion,
                in: versionsDirectory,
                rootDirectory: rootDirectory,
                nodeURL: runtime.nodeURL,
                port: port,
                environment: environment
            )
        }

        let update = try await checkForUpdates(using: runtime)
        return try await startInstalledRuntime(
            version: update.version,
            in: versionsDirectory,
            rootDirectory: rootDirectory,
            nodeURL: runtime.nodeURL,
            port: port,
            environment: environment
        )
    }

    func restart(using runtime: NodeRuntime, preferredVersion: String?) async throws -> DSHStartupResult {
        let rootDirectory = try applicationSupportDirectory()
        let versionsDirectory = runtimeVersionsDirectory(in: rootDirectory)
        let environment = processEnvironment(for: runtime)
        let version = preferredVersion
            ?? AppSettings.shared.selectedRuntimeVersion
            ?? currentRuntimeVersion(in: rootDirectory)

        guard let version else {
            return try await start(using: runtime)
        }

        return try await startInstalledRuntime(
            version: version,
            in: versionsDirectory,
            rootDirectory: rootDirectory,
            nodeURL: runtime.nodeURL,
            port: AppSettings.shared.port,
            environment: environment
        )
    }

    func downloadLatestAndStart(using runtime: NodeRuntime) async throws -> DSHStartupResult {
        let update = try await checkForUpdates(using: runtime)
        let rootDirectory = try applicationSupportDirectory()
        return try await startInstalledRuntime(
            version: update.version,
            in: runtimeVersionsDirectory(in: rootDirectory),
            rootDirectory: rootDirectory,
            nodeURL: runtime.nodeURL,
            port: AppSettings.shared.port,
            environment: processEnvironment(for: runtime)
        )
    }

    func checkForUpdates(
        using runtime: NodeRuntime,
        reportsProgress: Bool = true
    ) async throws -> DSHUpdateCheckResult {
        guard let npmURL = runtime.npmURL else {
            throw DSHRuntimeError.npmUnavailable
        }

        let rootDirectory = try applicationSupportDirectory()
        let versionsDirectory = runtimeVersionsDirectory(in: rootDirectory)
        let environment = processEnvironment(for: runtime)
        let packageManager = await packageManager(
            for: runtime,
            npmURL: npmURL,
            environment: environment,
            reportsProgress: reportsProgress
        )
        if reportsProgress {
            statusHandler("正在检查 DSH 更新…")
        }
        let release = try await resolveLatestRelease(npmURL: npmURL, environment: environment)
        let runtimeDirectory = versionsDirectory.appendingPathComponent(release.version, isDirectory: true)
        let executableURL = runtimeDirectory.appendingPathComponent("node_modules/.bin/dsh")

        guard !fileManager.isExecutableFile(atPath: executableURL.path) else {
            return .alreadyInstalled(release.version)
        }

        try fileManager.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        try removeIncompleteInstallation(in: runtimeDirectory)
        if reportsProgress {
            statusHandler("正在通过 \(packageManager.displayName) 下载 DSH \(release.version)…")
        }
        try writeManifest(for: release, to: runtimeDirectory)
        let installResult = try await runToCompletion(
            executableURL: packageManager.executableURL,
            arguments: packageManager.installArguments,
            directoryURL: runtimeDirectory,
            environment: environment
        )
        guard installResult.exitCode == 0 else {
            throw DSHRuntimeError.installFailed(compact(installResult.standardError))
        }
        try verifyIntegrity(of: release, in: runtimeDirectory, packageManager: packageManager)
        return .downloaded(release.version)
    }

    func installedVersions() -> [String] {
        guard let rootDirectory = try? applicationSupportDirectory() else { return [] }
        let versionsDirectory = runtimeVersionsDirectory(in: rootDirectory)
        return versionDirectories(in: versionsDirectory).map(\.version)
    }

    func runtimeVersionsDirectoryURL() -> URL? {
        guard let rootDirectory = try? applicationSupportDirectory() else { return nil }
        return runtimeVersionsDirectory(in: rootDirectory)
    }

    func preferredRuntimeVersion() -> String? {
        guard let rootDirectory = try? applicationSupportDirectory() else { return nil }
        return AppSettings.shared.selectedRuntimeVersion
            ?? currentRuntimeVersion(in: rootDirectory)
            ?? versionDirectories(in: runtimeVersionsDirectory(in: rootDirectory)).first?.version
    }

    func removeRuntimeVersion(_ version: String) throws {
        let rootDirectory = try applicationSupportDirectory()
        let runtimeDirectory = runtimeVersionsDirectory(in: rootDirectory).appendingPathComponent(version, isDirectory: true)
        guard fileManager.fileExists(atPath: runtimeDirectory.path) else { return }
        try fileManager.removeItem(at: runtimeDirectory)

        if currentRuntimeVersion(in: rootDirectory) == version {
            let currentLink = rootDirectory.appendingPathComponent("runtimes/current")
            try? fileManager.removeItem(at: currentLink)
        }
        if AppSettings.shared.selectedRuntimeVersion == version {
            AppSettings.shared.selectedRuntimeVersion = nil
        }
    }

    func stop() {
        if let dshProcess {
            expectedProcessTerminations.insert(dshProcess.processIdentifier)
            dshProcess.terminate()
        }
        dshProcess = nil
        if let managedServerPID {
            kill(managedServerPID, SIGTERM)
            self.managedServerPID = nil
        }
    }

    private func applicationSupportDirectory() throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base.appendingPathComponent("DshForMac", isDirectory: true)
        let runtimeRoot = root.appendingPathComponent("runtimes", isDirectory: true)
        let versionsDirectory = runtimeVersionsDirectory(in: root)
        try fileManager.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: versionsDirectory, withIntermediateDirectories: true)
        try migrateLegacyRuntimeDirectories(from: runtimeRoot, to: versionsDirectory)
        return root
    }

    private func processEnvironment(for runtime: NodeRuntime) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let nodeDirectory = runtime.nodeURL.deletingLastPathComponent().path
        environment["PATH"] = nodeDirectory + ":" + (environment["PATH"] ?? "")
        environment["npm_config_registry"] = AppSettings.shared.registry.url
        return environment
    }

    private func packageManager(
        for runtime: NodeRuntime,
        npmURL: URL,
        environment: [String: String],
        reportsProgress: Bool = true
    ) async -> PackageManager {
        if let pnpmURL = runtime.pnpmURL {
            return .pnpm(pnpmURL)
        }

        guard let corepackURL = runtime.corepackURL else {
            return .npm(npmURL)
        }

        if reportsProgress {
            statusHandler("未检测到 pnpm，正在通过 Corepack 启用…")
        }
        guard let result = try? await runToCompletion(
            executableURL: corepackURL,
            arguments: ["enable", "pnpm"],
            directoryURL: nil,
            environment: environment
        ), result.exitCode == 0 else {
            return .npm(npmURL)
        }

        let pnpmURL = runtime.nodeURL
            .deletingLastPathComponent()
            .appendingPathComponent("pnpm")
        return fileManager.isExecutableFile(atPath: pnpmURL.path) ? .pnpm(pnpmURL) : .npm(npmURL)
    }

    private func updateCurrentRuntimeLink(to version: String, in rootDirectory: URL) throws {
        let runtimeRoot = rootDirectory.appendingPathComponent("runtimes", isDirectory: true)
        let currentLink = runtimeRoot.appendingPathComponent("current")
        let temporaryLink = runtimeRoot.appendingPathComponent(".current-\(UUID().uuidString)")

        try fileManager.createSymbolicLink(
            atPath: temporaryLink.path,
            withDestinationPath: "versions/\(version)"
        )

        do {
            if fileManager.fileExists(atPath: currentLink.path)
                || (try? fileManager.destinationOfSymbolicLink(atPath: currentLink.path)) != nil
            {
                try fileManager.removeItem(at: currentLink)
            }
            try fileManager.moveItem(at: temporaryLink, to: currentLink)
        } catch {
            try? fileManager.removeItem(at: temporaryLink)
            throw error
        }
    }

    private func currentRuntimeVersion(in rootDirectory: URL) -> String? {
        let currentLink = rootDirectory.appendingPathComponent("runtimes/current")
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: currentLink.path) else {
            return nil
        }
        let version = URL(fileURLWithPath: destination).lastPathComponent
        return SemanticVersion(string: version) == nil ? nil : version
    }

    private func runtimeVersionsDirectory(in rootDirectory: URL) -> URL {
        rootDirectory
            .appendingPathComponent("runtimes", isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
    }

    private func migrateLegacyRuntimeDirectories(from runtimeRoot: URL, to versionsDirectory: URL) throws {
        let contents = try fileManager.contentsOfDirectory(
            at: runtimeRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for item in contents {
            let name = item.lastPathComponent
            guard name != "versions", name != "current",
                  SemanticVersion(string: name) != nil,
                  let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true
            else {
                continue
            }

            let destination = versionsDirectory.appendingPathComponent(name, isDirectory: true)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try fileManager.moveItem(at: item, to: destination)
        }
    }

    private func startInstalledRuntime(
        version: String,
        in versionsDirectory: URL,
        rootDirectory: URL,
        nodeURL: URL,
        port: Int,
        environment: [String: String]
    ) async throws -> DSHStartupResult {
        let runtimeDirectory = versionsDirectory.appendingPathComponent(version, isDirectory: true)
        let executableURL = runtimeDirectory.appendingPathComponent("node_modules/.bin/dsh")
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw DSHRuntimeError.selectedVersionUnavailable(version)
        }

        statusHandler("正在启动 DSH \(version)…")
        let address = URL(string: "http://127.0.0.1:\(port)/")!
        await stopRunningProcess()
        try await stopExistingManagedServer(in: rootDirectory, port: port)
        try startServer(
            nodeURL: nodeURL,
            directoryURL: runtimeDirectory,
            port: port,
            environment: environment
        )
        try await waitUntilHealthy(address: address)
        try updateCurrentRuntimeLink(to: version, in: rootDirectory)
        try removeOlderRuntimeVersions(in: versionsDirectory, currentVersion: version)
        return DSHStartupResult(address: address, version: version)
    }

    private func versionDirectories(in versionsDirectory: URL) -> [(version: String, url: URL)] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: versionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return contents.compactMap { item in
            guard SemanticVersion(string: item.lastPathComponent) != nil,
                  (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else {
                return nil
            }
            return (item.lastPathComponent, item)
        }.sorted { lhs, rhs in
            let leftVersion = SemanticVersion(string: lhs.version)!
            let rightVersion = SemanticVersion(string: rhs.version)!
            if leftVersion == rightVersion {
                return lhs.version > rhs.version
            }
            return leftVersion > rightVersion
        }
    }

    private func removeOlderRuntimeVersions(in versionsDirectory: URL, currentVersion: String) throws {
        let protectedVersions = Set([currentVersion, AppSettings.shared.selectedRuntimeVersion].compactMap { $0 })
        let versions = versionDirectories(in: versionsDirectory)
        var retainedVersions = Set(versions.prefix(3).map(\.version))
        retainedVersions.formUnion(protectedVersions)
        for version in versions where !retainedVersions.contains(version.version) {
            try fileManager.removeItem(at: version.url)
        }
    }

    private func resolveLatestRelease(
        npmURL: URL,
        environment: [String: String]
    ) async throws -> DSHRelease {
        let result = try await runToCompletion(
            executableURL: npmURL,
            arguments: [
                "view",
                "@deepseek-ai/dsh@latest",
                "version",
                "dist.integrity",
                "--json",
            ],
            directoryURL: nil,
            environment: environment
        )
        guard result.exitCode == 0,
              let data = result.standardOutput.data(using: .utf8),
              let release = try? JSONDecoder().decode(DSHRelease.self, from: data),
              SemanticVersion(string: release.version) != nil,
              release.integrity.hasPrefix("sha")
        else {
            throw DSHRuntimeError.metadataInvalid
        }
        return release
    }

    private func writeManifest(for release: DSHRelease, to directory: URL) throws {
        let manifest: [String: Any] = [
            "name": "dshformac-runtime-\(release.version)",
            "private": true,
            "dependencies": ["@deepseek-ai/dsh": release.version],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("package.json"), options: .atomic)
    }

    private func removeIncompleteInstallation(in directory: URL) throws {
        let paths = ["node_modules", "package-lock.json", "pnpm-lock.yaml"]
        for path in paths {
            let item = directory.appendingPathComponent(path)
            if fileManager.fileExists(atPath: item.path) {
                try fileManager.removeItem(at: item)
            }
        }
    }

    private func verifyIntegrity(
        of release: DSHRelease,
        in directory: URL,
        packageManager: PackageManager
    ) throws {
        switch packageManager {
        case .npm:
            try verifyNpmIntegrity(of: release, in: directory)
        case .pnpm:
            try verifyPnpmIntegrity(of: release, in: directory)
        }
    }

    private func verifyNpmIntegrity(of release: DSHRelease, in directory: URL) throws {
        let lockfileURL = directory.appendingPathComponent("package-lock.json")
        guard let data = try? Data(contentsOf: lockfileURL),
              let lockfile = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let packages = lockfile["packages"] as? [String: Any],
              let dshEntry = packages["node_modules/@deepseek-ai/dsh"] as? [String: Any],
              dshEntry["integrity"] as? String == release.integrity
        else {
            throw DSHRuntimeError.integrityMismatch
        }
    }

    private func verifyPnpmIntegrity(of release: DSHRelease, in directory: URL) throws {
        let lockfileURL = directory.appendingPathComponent("pnpm-lock.yaml")
        guard let lockfile = try? String(contentsOf: lockfileURL, encoding: .utf8),
              lockfile.contains("@deepseek-ai/dsh@\(release.version)"),
              lockfile.contains(release.integrity)
        else {
            throw DSHRuntimeError.integrityMismatch
        }
    }

    private func startServer(
        nodeURL: URL,
        directoryURL: URL,
        port: Int,
        environment: [String: String]
    ) throws {
        recentOutput = ""

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let entryPointURL = directoryURL.appendingPathComponent("node_modules/@deepseek-ai/dsh/lib/bin.js")
        process.executableURL = nodeURL
        process.arguments = [
            entryPointURL.path,
            "web",
            "--no-open",
            "--port",
            String(port),
        ]
        process.currentDirectoryURL = directoryURL
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        captureOutput(from: outputPipe)
        captureOutput(from: errorPipe)
        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasExpected = self.expectedProcessTerminations.remove(terminatedProcess.processIdentifier) != nil
                guard self.dshProcess === terminatedProcess else { return }
                self.dshProcess = nil
                self.managedServerPID = nil
                guard !wasExpected else { return }
                self.statusHandler("DSH 已退出（状态码 \(terminatedProcess.terminationStatus)）。")
            }
        }

        try process.run()
        dshProcess = process
        managedServerPID = process.processIdentifier
    }

    private func stopRunningProcess() async {
        guard let process = dshProcess else { return }
        expectedProcessTerminations.insert(process.processIdentifier)
        process.terminate()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        if dshProcess === process {
            dshProcess = nil
            managedServerPID = nil
        }
    }

    private func stopExistingManagedServer(in rootDirectory: URL, port: Int) async throws {
        guard let processID = try await listeningProcessID(port: port) else { return }
        let command = try await processCommand(for: processID)
        guard command.contains(rootDirectory.path) else {
            throw DSHRuntimeError.portInUse(port)
        }

        kill(processID, SIGTERM)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if try await listeningProcessID(port: port) == nil {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw DSHRuntimeError.portInUse(port)
    }

    private func listeningProcessID(port: Int) async throws -> pid_t? {
        let result = try await runToCompletion(
            executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"],
            directoryURL: nil,
            environment: ProcessInfo.processInfo.environment
        )
        guard result.exitCode == 0,
              let firstLine = result.standardOutput.split(whereSeparator: \.isNewline).first,
              let processID = pid_t(firstLine)
        else {
            return nil
        }
        return processID
    }

    private func processCommand(for processID: pid_t) async throws -> String {
        let result = try await runToCompletion(
            executableURL: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-p", String(processID), "-o", "command="],
            directoryURL: nil,
            environment: ProcessInfo.processInfo.environment
        )
        return result.standardOutput
    }

    private func waitUntilHealthy(address: URL) async throws {
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if dshProcess == nil {
                throw DSHRuntimeError.startupTimedOut(compact(recentOutput))
            }
            if await respondsAt(address) {
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        stop()
        throw DSHRuntimeError.startupTimedOut(compact(recentOutput))
    }

    private func respondsAt(_ address: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            URLSession.shared.dataTask(with: address) { _, response, _ in
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                continuation.resume(returning: (200..<500).contains(statusCode))
            }.resume()
        }
    }

    private func runToCompletion(
        executableURL: URL,
        arguments: [String],
        directoryURL: URL?,
        environment: [String: String]
    ) async throws -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = directoryURL
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let outputCollector = OutputCollector()
        let errorCollector = OutputCollector()
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            outputCollector.append(handle.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            errorCollector.append(handle.availableData)
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { completedProcess in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                outputCollector.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
                errorCollector.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: CommandResult(
                    exitCode: completedProcess.terminationStatus,
                    standardOutput: outputCollector.string,
                    standardError: errorCollector.string
                ))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func captureOutput(from pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recentOutput = String((self.recentOutput + text).suffix(2_000))
            }
        }
    }

    private func compact(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : " \(String(trimmed.suffix(800)))"
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedData = Data()

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        storedData.append(data)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: storedData, encoding: .utf8) ?? ""
    }
}
