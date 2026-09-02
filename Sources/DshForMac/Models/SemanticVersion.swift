import Foundation

struct SemanticVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    private let prerelease: [PrereleaseIdentifier]?

    private enum PrereleaseIdentifier: Equatable, Sendable {
        case numeric(String)
        case text(String)

        var value: String {
            switch self {
            case let .numeric(value), let .text(value): value
            }
        }
    }

    init?(string: String) {
        let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        let versionAndPrerelease = cleaned.split(separator: "+", maxSplits: 1).first ?? Substring(cleaned)
        let components = versionAndPrerelease.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numericPart = components[0]
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

        if components.count == 2 {
            let identifiers = components[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !identifiers.isEmpty,
                  identifiers.allSatisfy({ !$0.isEmpty && $0.allSatisfy(Self.isValidPrereleaseCharacter) })
            else {
                return nil
            }
            prerelease = identifiers.map { identifier in
                let value = String(identifier)
                return identifier.allSatisfy(\.isNumber) ? .numeric(value) : .text(value)
            }
        } else {
            prerelease = nil
        }
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let numericComparison = (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        let numericEquality = (lhs.major, lhs.minor, lhs.patch) == (rhs.major, rhs.minor, rhs.patch)
        guard numericEquality else { return numericComparison }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        case let (.some(left), .some(right)):
            for (leftIdentifier, rightIdentifier) in zip(left, right) {
                if leftIdentifier == rightIdentifier { continue }
                return comparePrerelease(leftIdentifier, rightIdentifier)
            }
            return left.count < right.count
        }
    }

    private static func isValidPrereleaseCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "-")
    }

    private static func comparePrerelease(_ lhs: PrereleaseIdentifier, _ rhs: PrereleaseIdentifier) -> Bool {
        switch (lhs, rhs) {
        case let (.numeric(left), .numeric(right)):
            if left.count != right.count { return left.count < right.count }
            return left < right
        case (.numeric, .text):
            return true
        case (.text, .numeric):
            return false
        case let (.text(left), .text(right)):
            return left < right
        }
    }
}

extension SemanticVersion: CustomStringConvertible {
    var description: String {
        let suffix = prerelease.map { "-\($0.map(\.value).joined(separator: "."))" } ?? ""
        return "\(major).\(minor).\(patch)\(suffix)"
    }
}
