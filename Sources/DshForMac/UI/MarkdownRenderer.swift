import Foundation

enum MarkdownRenderer {
    static func render(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        var html: [String] = []
        var paragraph: [String] = []
        var isInCodeBlock = false
        var codeLines: [String] = []
        var isInUnorderedList = false
        var isInOrderedList = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            html.append("<p>\(paragraph.map(renderInline).joined(separator: "<br>"))</p>")
            paragraph.removeAll()
        }
        func closeLists() {
            if isInUnorderedList {
                html.append("</ul>")
                isInUnorderedList = false
            }
            if isInOrderedList {
                html.append("</ol>")
                isInOrderedList = false
            }
        }

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flushParagraph()
                closeLists()
                if isInCodeBlock {
                    html.append("<pre><code>\(escape(codeLines.joined(separator: "\n")))</code></pre>")
                    codeLines.removeAll()
                }
                isInCodeBlock.toggle()
                continue
            }
            if isInCodeBlock {
                codeLines.append(line)
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                closeLists()
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                closeLists()
                html.append("<hr>")
                continue
            }
            if let heading = headingHTML(for: trimmed) {
                flushParagraph()
                closeLists()
                html.append(heading)
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                closeLists()
                html.append("<blockquote>\(renderInline(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))</blockquote>")
                continue
            }
            if let item = unorderedListItem(in: trimmed) {
                flushParagraph()
                if isInOrderedList {
                    closeLists()
                }
                if !isInUnorderedList {
                    html.append("<ul>")
                    isInUnorderedList = true
                }
                html.append("<li>\(renderInline(item))</li>")
                continue
            }
            if let item = orderedListItem(in: trimmed) {
                flushParagraph()
                if isInUnorderedList {
                    closeLists()
                }
                if !isInOrderedList {
                    html.append("<ol>")
                    isInOrderedList = true
                }
                html.append("<li>\(renderInline(item))</li>")
                continue
            }
            closeLists()
            paragraph.append(line)
        }

        if isInCodeBlock {
            html.append("<pre><code>\(escape(codeLines.joined(separator: "\n")))</code></pre>")
        }
        flushParagraph()
        closeLists()
        return documentHTML(body: html.joined(separator: "\n"))
    }

    private static func headingHTML(for line: String) -> String? {
        let count = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(count), line.dropFirst(count).first == " " else { return nil }
        return "<h\(count)>\(renderInline(String(line.dropFirst(count)).trimmingCharacters(in: .whitespaces)))</h\(count)>"
    }

    private static func unorderedListItem(in line: String) -> String? {
        guard line.count > 2, ["-", "*", "+"].contains(line.first), line.dropFirst().first == " " else { return nil }
        return String(line.dropFirst(2))
    }

    private static func orderedListItem(in line: String) -> String? {
        guard let periodIndex = line.firstIndex(of: "."), line[..<periodIndex].allSatisfy({ $0.isNumber }) else { return nil }
        let contentStart = line.index(after: periodIndex)
        guard contentStart < line.endIndex, line[contentStart] == " " else { return nil }
        return String(line[line.index(after: contentStart)...])
    }

    private static func renderInline(_ string: String) -> String {
        var result = escape(string)
        result = replace(pattern: "`([^`]+)`", in: result, template: "<code>$1</code>")
        result = replace(pattern: "\\*\\*([^*]+)\\*\\*", in: result, template: "<strong>$1</strong>")
        result = replace(pattern: "__([^_]+)__", in: result, template: "<strong>$1</strong>")
        result = replace(pattern: "(?<!\\*)\\*([^*]+)\\*", in: result, template: "<em>$1</em>")
        result = replace(pattern: "(?<!_)_([^_]+)_", in: result, template: "<em>$1</em>")
        return result
    }

    private static func replace(pattern: String, in string: String, template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return string }
        let range = NSRange(string.startIndex..., in: string)
        return expression.stringByReplacingMatches(in: string, range: range, withTemplate: template)
    }

    private static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func documentHTML(body: String) -> String {
        """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <style>
        :root { color-scheme: light dark; }
        body { font: -apple-system-body; line-height: 1.55; margin: 24px; overflow-wrap: break-word; }
        h1,h2,h3,h4,h5,h6 { line-height: 1.25; margin: 1.15em 0 .5em; }
        p,ul,ol,blockquote { margin: .7em 0; }
        pre { overflow-x: auto; padding: 12px; border-radius: 8px; background: rgba(127,127,127,.14); }
        code { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; }
        p code,li code { padding: 1px 4px; border-radius: 4px; background: rgba(127,127,127,.14); }
        blockquote { border-left: 3px solid #8e8e93; padding-left: 12px; color: #6e6e73; }
        hr { border: 0; border-top: 1px solid rgba(127,127,127,.35); margin: 1.5em 0; }
        </style></head><body>\(body)</body></html>
        """
    }
}
