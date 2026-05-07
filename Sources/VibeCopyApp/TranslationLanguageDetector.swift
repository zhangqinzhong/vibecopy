import Foundation
import NaturalLanguage

enum TranslationLanguageDetector {
    static func automaticDirection(
        for text: String,
        supportedLanguages: [TranslationLanguageOption] = []
    ) -> (source: String, target: String) {
        let source = detectedSourceLanguage(for: text, supportedLanguages: supportedLanguages)
        let target = isChinese(source) ? "en-US" : "zh-Hans"
        return source == target ? (source, "en-US") : (source, target)
    }

    static func detectedSourceLanguage(
        for text: String,
        supportedLanguages: [TranslationLanguageOption] = []
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "en-US" }

        if containsChinese(trimmed) {
            return containsMostlyTraditionalChinese(trimmed) ? "zh-Hant" : "zh-Hans"
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)

        guard let dominantLanguage = recognizer.dominantLanguage else {
            return "en-US"
        }

        let detectedCode = canonicalLanguageCode(dominantLanguage.rawValue)
        return bestSupportedLanguageCode(for: detectedCode, supportedLanguages: supportedLanguages) ?? detectedCode
    }

    static func canonicalLanguageCode(_ identifier: String) -> String {
        switch identifier.replacingOccurrences(of: "_", with: "-") {
        case "zh", "zh-CN", "zh-Hans-CN":
            return "zh-Hans"
        case "zh-TW", "zh-Hant-TW":
            return "zh-Hant"
        case "en", "en-US", "en-Latn-US":
            return "en-US"
        default:
            return identifier.replacingOccurrences(of: "_", with: "-")
        }
    }

    static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value)) ||
                (0x3400...0x4DBF).contains(Int(scalar.value))
        }
    }

    private static func bestSupportedLanguageCode(
        for detectedCode: String,
        supportedLanguages: [TranslationLanguageOption]
    ) -> String? {
        guard !supportedLanguages.isEmpty else { return nil }

        let normalizedDetected = detectedCode.lowercased()
        if let exactMatch = supportedLanguages.first(where: { $0.id.lowercased() == normalizedDetected }) {
            return exactMatch.id
        }

        let detectedBase = normalizedDetected.split(separator: "-").first.map(String.init) ?? normalizedDetected
        if let baseMatch = supportedLanguages.first(where: { option in
            let optionCode = option.id.lowercased()
            return optionCode == detectedBase || optionCode.hasPrefix("\(detectedBase)-")
        }) {
            return baseMatch.id
        }

        return nil
    }

    private static func isChinese(_ identifier: String) -> Bool {
        identifier.lowercased().hasPrefix("zh")
    }

    private static func containsMostlyTraditionalChinese(_ text: String) -> Bool {
        let traditionalOnlyScalars: Set<UnicodeScalar> = [
            "繁", "體", "臺", "灣", "國", "語", "門", "開", "關", "車", "電", "腦", "學", "習", "後", "與", "會"
        ].compactMap { $0.unicodeScalars.first }.reduce(into: Set<UnicodeScalar>()) { $0.insert($1) }

        return text.unicodeScalars.contains { traditionalOnlyScalars.contains($0) }
    }
}
