import Foundation

enum DSHCompatibility {
    static var minimumVersion: String { AppMetadata.minimumSupportedDSHVersion }

    static func supports(_ version: String) -> Bool {
        guard let candidate = SemanticVersion(string: version),
              let minimum = SemanticVersion(string: minimumVersion)
        else { return false }
        return candidate >= minimum
    }
}
