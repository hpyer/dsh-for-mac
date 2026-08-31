import Foundation

struct SemanticVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(string: String) {
        let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        let numericPart = cleaned.split(separator: "-", maxSplits: 1).first ?? Substring(cleaned)
        let parts = numericPart.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let major = Int(parts[0]),
              let minor = Int(parts[1])
        else {
            return nil
        }

        self.major = major
        self.minor = minor
        self.patch = parts.count >= 3 ? Int(parts[2]) ?? 0 : 0
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

extension SemanticVersion: CustomStringConvertible {
    var description: String { "\(major).\(minor).\(patch)" }
}
