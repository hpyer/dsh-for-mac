import Foundation
import Testing
@testable import DshForMac

struct SystemSearchPathTests {
    @Test func readsSystemPathsAndSortedDropInsWithoutShellExpansion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("paths.d")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("paths")
        try "/usr/bin\n/bin\n\n# comment\nrelative\n/bad:/entry\n".write(to: file, atomically: true, encoding: .utf8)
        try "/Library/Apple/usr/bin\n".write(to: directory.appendingPathComponent("20-apple"), atomically: true, encoding: .utf8)
        try "/custom tools/bin\n".write(to: directory.appendingPathComponent("10-tools"), atomically: true, encoding: .utf8)
        #expect(SystemSearchPath.directories(pathsFile: file, pathsDirectory: directory) == [
            "/usr/bin", "/bin", "/custom tools/bin", "/Library/Apple/usr/bin",
        ])
        #expect(SystemSearchPath.directories(
            pathsFile: root.appendingPathComponent("missing"),
            pathsDirectory: root.appendingPathComponent("missing.d")
        ).isEmpty)
    }
}
