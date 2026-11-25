import Foundation

public enum AnswerBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(String)
    case item(marker: String, body: String)
    case code(String)
}

public enum AnswerPresentation {
    public static func blocks(for text: String, format: AnswerFormat) -> [AnswerBlock] {
        var result: [AnswerBlock] = []
        var paragraph: [String] = []
        var code: [String]?
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            result.append(contentsOf: prose(paragraph.joined(separator: "\n"), format: format))
            paragraph.removeAll(keepingCapacity: true)
        }

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flushParagraph()
                if let lines = code {
                    result.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(String(rawLine))
                continue
            }

            for segment in splitSections(line, format: format) {
                if let block = separateBlock(segment) {
                    flushParagraph()
                    result.append(block)
                } else if segment.isEmpty {
                    flushParagraph()
                } else {
                    paragraph.append(segment)
                }
            }
        }
        flushParagraph()
        if let code, !code.isEmpty { result.append(.code(code.joined(separator: "\n"))) }
        return result
    }

    private static func separateBlock(_ line: String) -> AnswerBlock? {
        let titleMarker = line.prefix(while: { $0 == "#" })
        if (1...6).contains(titleMarker.count), line.dropFirst(titleMarker.count).hasPrefix(" ") {
            return .heading(String(line.dropFirst(titleMarker.count + 1)))
        }
        if ["- ", "* ", "+ "].contains(where: line.hasPrefix) {
            return .item(marker: "•", body: String(line.dropFirst(2)))
        }
        let number = line.prefix(while: \.isNumber)
        if !number.isEmpty, line.dropFirst(number.count).hasPrefix(". ") {
            return .item(marker: String(number) + ".", body: String(line.dropFirst(number.count + 2)))
        }
        return nil
    }

    private static func splitSections(_ line: String, format: AnswerFormat) -> [String] {
        let expression: NSRegularExpression?
        switch format {
        case .star: expression = starSections
        case .technical: expression = technicalSections
        default: return [line]
        }
        guard let expression else { return [line] }
        let matches = expression.matches(in: line, range: NSRange(line.startIndex..., in: line))
        guard !matches.isEmpty else { return [line] }
        var result: [String] = []
        var start = line.startIndex
        for match in matches {
            guard let marker = Range(match.range, in: line), let title = Range(match.range(at: 1), in: line) else { continue }
            let introduction = line[start..<marker.lowerBound].trimmingCharacters(in: .whitespaces)
            if !introduction.isEmpty { result.append(introduction) }
            result.append("## " + String(line[title]).capitalized)
            start = marker.upperBound
        }
        let rest = line[start...].trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { result.append(rest) }
        return result
    }

    private static func prose(_ text: String, format: AnswerFormat) -> [AnswerBlock] {
        guard format != .ultraBrief else { return [.paragraph(text)] }
        let sentences = splitSentences(text)
        if format == .bullets {
            return sentences.map { .item(marker: "•", body: $0) }
        }
        let perParagraph = format == .standard ? 3 : 2
        guard sentences.count > perParagraph else { return [.paragraph(text)] }
        return stride(from: 0, to: sentences.count, by: perParagraph).map { first in
            let end = min(first + perParagraph, sentences.count)
            return .paragraph(sentences[first..<end].joined(separator: " "))
        }
    }

    private static func splitSentences(_ text: String) -> [String] {
        guard let sentenceBoundary else { return [text] }
        let matches = sentenceBoundary.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var parts: [String] = []
        var start = text.startIndex
        for match in matches {
            guard let separator = Range(match.range, in: text) else { continue }
            let sentence = text[start..<separator.lowerBound]
            let lastWord = sentence.split(whereSeparator: \.isWhitespace).last?.lowercased()
            if let lastWord, sentenceAbbreviations.contains(lastWord) { continue }
            parts.append(String(sentence))
            start = separator.upperBound
        }
        parts.append(String(text[start...]))
        return parts
    }

    private static let sentenceAbbreviations: Set<String> = ["dr.", "mr.", "mrs.", "ms.", "prof.", "e.g.", "i.e."]
    private static let sentenceBoundary = try? NSRegularExpression(pattern: #"(?<=[.!?])\s+(?=[\p{Lu}\p{N}“"])"#)
    private static let starSections = sectionPattern("Situation|Task|Action|Result")
    private static let technicalSections = sectionPattern("Approach|Implementation|Trade-offs|Complexity|Validation|Edge cases|Example")

    private static func sectionPattern(_ titles: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: #"(?i)(?:^|(?<=[.!?])\s+)(?:\*\*|__)?("# + titles + #")(?:\*\*|__)?\s*:\s*(?:\*\*|__)?\s*"#)
    }
}
