import AppKit

@MainActor
enum GenericSyntaxHighlighter {
    private static let baseFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    private static let keywordFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
    private static let keywordPattern = [
        "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "default",
        "defer", "do", "else", "enum", "export", "extends", "false", "final", "for", "from", "func",
        "function", "guard", "if", "import", "in", "interface", "let", "mutating", "new", "nil", "null",
        "private", "protected", "public", "return", "self", "static", "struct", "switch", "throw", "throws",
        "true", "try", "type", "var", "void", "while", "with", "yield"
    ].joined(separator: "|")

    private static let tokenExpression: NSRegularExpression = {
        let pattern = "(\\/\\*[\\s\\S]*?\\*\\/)|(\\/\\/[^\\n]*|(?m:^\\s*#[^\\n]*))|(\\\"(?:\\\\.|[^\\\"\\\\])*\\\")|('(?:\\\\.|[^'\\\\])*')|(\\b(?:\\d+(?:\\.\\d+)?|0x[0-9A-Fa-f]+)\\b)|(\\b(?:\(keywordPattern))\\b)"
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static let keyExpression = try! NSRegularExpression(
        pattern: "(?m)^\\s*(?:[-*]\\s+)?([A-Za-z_][A-Za-z0-9_.-]*)(?=\\s*[:=])"
    )
    private static let tagExpression = try! NSRegularExpression(pattern: "<\\/?[A-Za-z][^>]*>")

    static func attributedText(for text: String, fileName: String) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        let fullRange = NSRange(text.startIndex..., in: text)

        tokenExpression.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let match else { return }
            if match.range(at: 1).location != NSNotFound || match.range(at: 2).location != NSNotFound {
                result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: match.range)
            } else if match.range(at: 3).location != NSNotFound || match.range(at: 4).location != NSNotFound {
                result.addAttribute(.foregroundColor, value: NSColor.systemRed, range: match.range)
            } else if match.range(at: 5).location != NSNotFound {
                result.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: match.range)
            } else if match.range(at: 6).location != NSNotFound {
                result.addAttributes([
                    .foregroundColor: NSColor.systemBlue,
                    .font: keywordFont,
                ], range: match.range)
            }
        }

        keyExpression.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let match, match.numberOfRanges > 1 else { return }
            result.addAttributes([
                .foregroundColor: NSColor.systemTeal,
                .font: keywordFont,
            ], range: match.range(at: 1))
        }

        if ["html", "htm", "xml", "svg", "vue", "svelte"].contains(URL(fileURLWithPath: fileName).pathExtension.lowercased()) {
            tagExpression.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let match else { return }
                result.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: match.range)
            }
        }

        return result
    }
}
