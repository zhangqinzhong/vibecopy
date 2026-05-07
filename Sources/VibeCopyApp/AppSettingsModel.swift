import AppKit
import SwiftUI
import Translation

enum AppThemePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var resolvedColorScheme: ColorScheme {
        switch self {
        case .system:
            return Self.systemColorScheme
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    var resolvedAppearance: NSAppearance? {
        switch resolvedColorScheme {
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        @unknown default:
            return NSAppearance(named: .aqua)
        }
    }

    var resolvesToDark: Bool {
        resolvedColorScheme == .dark
    }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    private static var systemColorScheme: ColorScheme {
        let matched = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return matched == .darkAqua ? .dark : .light
    }
}

struct TranslationLanguageOption: Identifiable, Hashable {
    let id: String
    let language: Locale.Language

    var displayName: String {
        Locale.current.localizedString(forIdentifier: id) ?? id
    }

    var nativeName: String {
        Locale(identifier: id).localizedString(forIdentifier: id) ?? displayName
    }
}

struct TranslationLanguageStatus: Identifiable {
    let id: String
    let language: TranslationLanguageOption
    var state: String
    var detail: String
    var canDownload: Bool
}

@MainActor
final class AppSettingsModel: ObservableObject {
    private enum DefaultsKey {
        static let themePreference = "settings.themePreference"
        static let sourceLanguage = "settings.sourceLanguage"
        static let targetLanguage = "settings.targetLanguage"
    }

    @Published var themePreference: AppThemePreference {
        didSet {
            UserDefaults.standard.set(themePreference.rawValue, forKey: DefaultsKey.themePreference)
        }
    }

    @Published var sourceLanguageCode: String {
        didSet {
            UserDefaults.standard.set(sourceLanguageCode, forKey: DefaultsKey.sourceLanguage)
        }
    }

    @Published var targetLanguageCode: String {
        didSet {
            UserDefaults.standard.set(targetLanguageCode, forKey: DefaultsKey.targetLanguage)
        }
    }

    @Published var supportedLanguages: [TranslationLanguageOption] = AppSettingsModel.fallbackLanguages
    @Published var languageStatuses: [TranslationLanguageStatus] = []
    @Published var languageStatusMessage = "语言状态会在打开设置时刷新。"
    @Published var isRefreshingLanguages = false
    @Published var isPreparingLanguagePack = false

    var preferredColorScheme: ColorScheme? {
        themePreference.resolvedColorScheme
    }

    init() {
        themePreference = AppThemePreference(
            rawValue: UserDefaults.standard.string(forKey: DefaultsKey.themePreference) ?? ""
        ) ?? .system
        let savedSourceLanguage = UserDefaults.standard.string(forKey: DefaultsKey.sourceLanguage)
        sourceLanguageCode = Self.normalizedInitialSourceLanguage(savedSourceLanguage)
        let savedTargetLanguage = UserDefaults.standard.string(forKey: DefaultsKey.targetLanguage)
        targetLanguageCode = Self.normalizedInitialTargetLanguage(savedTargetLanguage)
    }

    func refreshSupportedLanguages() {
        guard !isRefreshingLanguages else { return }
        isRefreshingLanguages = true
        languageStatusMessage = "正在刷新系统支持语言..."

        Task { @MainActor in
            let availability = LanguageAvailability()
            let languages = await availability.supportedLanguages
            let options = languages
                .map { TranslationLanguageOption(id: $0.minimalIdentifier, language: $0) }
                .sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }

            supportedLanguages = options
            normalizeSelectedLanguages()
            await refreshLanguageStatuses()
            isRefreshingLanguages = false
        }
    }

    func refreshLanguageStatuses() async {
        let availability = LanguageAvailability()
        var rows: [TranslationLanguageStatus] = []

        for option in supportedLanguages {
            let status = await availability.status(from: option.language, to: nil)
            guard status != .unsupported else { continue }

            rows.append(TranslationLanguageStatus(
                id: option.id,
                language: option,
                state: label(for: status),
                detail: detail(for: status),
                canDownload: status == .supported
            ))
        }

        languageStatuses = rows
        languageStatusMessage = rows.isEmpty ? "系统没有返回可管理的 Translation 语言包。" : "已刷新 \(rows.count) 个系统 Translation 语言包。"
    }

    func selectSourceLanguage(_ option: TranslationLanguageOption) {
        guard option.id != targetLanguageCode else {
            languageStatusMessage = "源语言和目标语言不能相同。"
            return
        }
        sourceLanguageCode = option.id
    }

    func selectTargetLanguage(_ option: TranslationLanguageOption) {
        guard option.id != sourceLanguageCode else {
            languageStatusMessage = "源语言和目标语言不能相同。"
            return
        }
        targetLanguageCode = option.id
        Task { @MainActor in await refreshLanguageStatuses() }
    }

    func swapLanguages() {
        swap(&sourceLanguageCode, &targetLanguageCode)
    }

    func prepareSelectedLanguagePack() {
        prepareLanguagePack(source: sourceLanguageCode, target: targetLanguageCode)
    }

    func prepareLanguagePack(for option: TranslationLanguageOption) {
        prepareLanguagePack(source: option.id, target: nil)
    }

    func prepareLanguagePack(source: String, target: String?) {
        if let target, source == target {
            languageStatusMessage = "源语言和目标语言不能相同。"
            return
        }

        isPreparingLanguagePack = true
        languageStatusMessage = "正在打开系统语言包下载提示..."
        TranslationService.prepareLanguagePack(sourceLanguage: source, targetLanguage: target) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isPreparingLanguagePack = false
                self.languageStatusMessage = "语言包准备流程已结束，正在刷新状态。"
                await self.refreshLanguageStatuses()
            }
        }
    }

    func language(for code: String) -> Locale.Language {
        if let option = supportedLanguages.first(where: { $0.id == code }) {
            return option.language
        }
        return Locale.Language(identifier: code)
    }

    func languageLabel(for code: String) -> String {
        if let option = supportedLanguages.first(where: { $0.id == code }) {
            return option.displayName
        }

        switch code {
        case "zh_CN", "zh-Hans": return "中文（普通话，简体）"
        case "zh_TW", "zh-Hant": return "中文（繁体）"
        case "en_US", "en-US": return "英语（美国）"
        default: return Locale.current.localizedString(forIdentifier: code) ?? code
        }
    }

    private func normalizeSelectedLanguages() {
        sourceLanguageCode = Self.canonicalLanguageCode(sourceLanguageCode)
        targetLanguageCode = Self.canonicalLanguageCode(targetLanguageCode)

        if !supportedLanguages.contains(where: { $0.id == sourceLanguageCode }) {
            sourceLanguageCode = Self.preferredSimplifiedChinese(in: supportedLanguages)?.id
                ?? supportedLanguages.first?.id
                ?? "zh-Hans"
        }
        if !supportedLanguages.contains(where: { $0.id == targetLanguageCode }) {
            targetLanguageCode = supportedLanguages.first(where: { $0.id.hasPrefix("en") })?.id
                ?? supportedLanguages.dropFirst().first?.id
                ?? "en-US"
        }
        if sourceLanguageCode == targetLanguageCode {
            targetLanguageCode = supportedLanguages.first(where: { $0.id != sourceLanguageCode })?.id ?? "en-US"
        }
    }

    private static func normalizedInitialSourceLanguage(_ savedLanguage: String?) -> String {
        guard let savedLanguage, !savedLanguage.isEmpty else {
            return "zh-Hans"
        }
        return isTraditionalChinese(savedLanguage) ? "zh-Hans" : savedLanguage
    }

    private static func normalizedInitialTargetLanguage(_ savedLanguage: String?) -> String {
        guard let savedLanguage, !savedLanguage.isEmpty else {
            return "en-US"
        }
        return canonicalLanguageCode(savedLanguage)
    }

    private static func canonicalLanguageCode(_ identifier: String) -> String {
        switch identifier.replacingOccurrences(of: "_", with: "-") {
        case "zh-CN", "zh-Hans-CN":
            return "zh-Hans"
        case "zh-TW", "zh-Hant-TW":
            return "zh-Hant"
        case "en-US", "en-Latn-US":
            return "en-US"
        default:
            return identifier.replacingOccurrences(of: "_", with: "-")
        }
    }

    private static func preferredSimplifiedChinese(in options: [TranslationLanguageOption]) -> TranslationLanguageOption? {
        options
            .filter { isSimplifiedChinese($0.id) }
            .sorted { simplifiedChineseRank($0.id) < simplifiedChineseRank($1.id) }
            .first
    }

    private static func isSimplifiedChinese(_ identifier: String) -> Bool {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        return normalized == "zh"
            || normalized.hasPrefix("zh-hans")
            || normalized.hasPrefix("zh-cn")
            || normalized.hasPrefix("zh-sg")
    }

    private static func isTraditionalChinese(_ identifier: String) -> Bool {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        return normalized.hasPrefix("zh-hant")
            || normalized.hasPrefix("zh-tw")
            || normalized.hasPrefix("zh-hk")
            || normalized.hasPrefix("zh-mo")
    }

    private static func simplifiedChineseRank(_ identifier: String) -> Int {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        if normalized == "zh-hans" { return 0 }
        if normalized == "zh-hans-cn" { return 1 }
        if normalized == "zh-cn" { return 2 }
        if normalized.hasPrefix("zh-hans") { return 3 }
        if normalized.hasPrefix("zh-sg") { return 4 }
        return 5
    }

    private func label(for status: LanguageAvailability.Status) -> String {
        switch status {
        case .installed: return "已下载"
        case .supported: return "未下载"
        case .unsupported: return "不支持"
        @unknown default: return "未知"
        }
    }

    private func detail(for status: LanguageAvailability.Status) -> String {
        switch status {
        case .installed: return "系统语言包已可用"
        case .supported: return "系统支持，尚未下载"
        case .unsupported: return "系统 Translation 不支持"
        @unknown default: return "请刷新后重试"
        }
    }

    private static let fallbackLanguages = [
        TranslationLanguageOption(id: "zh-Hans", language: Locale.Language(identifier: "zh-Hans")),
        TranslationLanguageOption(id: "en-US", language: Locale.Language(identifier: "en-US")),
        TranslationLanguageOption(id: "ja-JP", language: Locale.Language(identifier: "ja-JP")),
        TranslationLanguageOption(id: "ko-KR", language: Locale.Language(identifier: "ko-KR")),
        TranslationLanguageOption(id: "fr-FR", language: Locale.Language(identifier: "fr-FR")),
        TranslationLanguageOption(id: "de-DE", language: Locale.Language(identifier: "de-DE")),
        TranslationLanguageOption(id: "es-ES", language: Locale.Language(identifier: "es-ES"))
    ]
}

private extension Locale.Language {
    var minimalIdentifier: String {
        var parts: [String] = []
        if let languageCode {
            parts.append(languageCode.identifier)
        }
        if let script {
            parts.append(script.identifier)
        }
        if let region {
            parts.append(region.identifier)
        }
        return parts.isEmpty ? "\(self)" : parts.joined(separator: "-")
    }
}
