import Foundation

public struct DictionaryEntry: Codable, Sendable {
    public let spokenForms: [String]
    public let target: String

    public init(spokenForms: [String], target: String) {
        self.spokenForms = spokenForms
        self.target = target
    }
}

public struct DictionaryEngine: Sendable {
    private let entries: [DictionaryEntry]
    private let chineseScriptPreference: ChineseScriptPreference

    public init(
        entries: [DictionaryEntry],
        chineseScriptPreference: ChineseScriptPreference = .fromPreferredLanguages()
    ) {
        self.entries = entries
        self.chineseScriptPreference = chineseScriptPreference
    }

    public func normalize(_ text: String) -> String {
        let replaced = entries.reduce(text) { partial, entry in
            entry.spokenForms.reduce(partial) { phraseResult, spokenForm in
                phraseResult.replacingOccurrences(
                    of: spokenForm,
                    with: entry.target,
                    options: [.caseInsensitive, .diacriticInsensitive]
                )
            }
        }

        let normalizedSpacing = normalizeSpacing(in: replaced)
        let normalizedScript = chineseScriptPreference.normalize(normalizedSpacing)
        return ensureTrailingPunctuation(in: normalizedScript)
    }

    private func normalizeSpacing(in text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        value = value.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        value = value.replacingOccurrences(
            of: #"([\p{Han}])([A-Za-z0-9])"#,
            with: "$1 $2",
            options: .regularExpression
        )

        value = value.replacingOccurrences(
            of: #"([A-Za-z0-9])([\p{Han}])"#,
            with: "$1 $2",
            options: .regularExpression
        )

        return value
    }

    private func ensureTrailingPunctuation(in text: String) -> String {
        guard let lastCharacter = text.last else {
            return text
        }

        let terminalPunctuation: Set<Character> = [".", "!", "?", "。", "！", "？", "…"]
        guard !terminalPunctuation.contains(lastCharacter) else {
            return text
        }

        let containsChinese = text.range(of: #"\p{Han}"#, options: .regularExpression) != nil
        return text + (containsChinese ? "。" : ".")
    }
}
