import Foundation

public enum ChineseScriptPreference: Sendable {
    case preserve
    case simplified
    case traditional

    public static func fromPreferredLanguages(
        _ preferredLanguages: [String] = Locale.preferredLanguages
    ) -> ChineseScriptPreference {
        for language in preferredLanguages {
            let normalized = language.lowercased()
            if normalized.hasPrefix("zh-hant") || normalized.hasPrefix("zh-tw") || normalized.hasPrefix("zh-hk") || normalized.hasPrefix("zh-mo") {
                return .traditional
            }

            if normalized.hasPrefix("zh-hans") || normalized.hasPrefix("zh-cn") || normalized.hasPrefix("zh-sg") {
                return .simplified
            }
        }

        return .preserve
    }

    public var whisperPromptInstruction: String? {
        switch self {
        case .preserve:
            return "Use mixed Chinese and English output naturally. Preserve English technical terms, product names, and letter casing."
        case .simplified:
            return "请使用简体中文与 English 混合输出，自然补全标点，保留英文术语、产品名称和大小写。"
        case .traditional:
            return "請使用繁體中文與 English 混合輸出，自然補全標點，保留英文術語、產品名稱和大小寫。"
        }
    }

    public func normalize(_ text: String) -> String {
        guard text.range(of: #"\p{Han}"#, options: .regularExpression) != nil else {
            return text
        }

        let transformName: String
        switch self {
        case .preserve:
            return text
        case .simplified:
            transformName = "Traditional-Simplified"
        case .traditional:
            transformName = "Simplified-Traditional"
        }

        let mutable = NSMutableString(string: text)
        let success = CFStringTransform(mutable, nil, transformName as CFString, false)
        return success ? String(mutable) : text
    }
}
