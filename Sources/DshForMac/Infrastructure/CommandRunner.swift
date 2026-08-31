import Foundation

struct CommandResult: Equatable, Sendable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

protocol CommandRunning {
    func run(executableURL: URL, arguments: [String], environment: [String: String]?) throws -> CommandResult
}

enum CommandRunnerError: LocalizedError {
    case couldNotDecodeOutput

    var errorDescription: String? {
        switch self {
        case .couldNotDecodeOutput:
            "命令输出无法按 UTF-8 解码。"
        }
    }
}

struct ProcessCommandRunner: CommandRunning {
    func run(executableURL: URL, arguments: [String], environment: [String: String]? = nil) throws -> CommandResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()

        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: outputData, encoding: .utf8),
              let error = String(data: errorData, encoding: .utf8)
        else {
            throw CommandRunnerError.couldNotDecodeOutput
        }

        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: output,
            standardError: error
        )
    }
}
