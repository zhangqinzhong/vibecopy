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

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
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
        themePreference.colorScheme
    }

    init() {
        themePreference = AppThemePreference(
            rawValue: UserDefaults.standard.string(forKey: DefaultsKey.themePreference) ?? ""
        ) ?? .system
        sourceLanguageCode = UserDefaults.standard.string(forKey: DefaultsKey.sourceLanguage) ?? "zh-Hans"
        targetLanguageCode = UserDefaults.standard.string(forKey: DefaultsKey.targetLanguage) ?? "en-US"
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

            supportedLanguages = options.isEmpty ? Self.fallbackLanguages : options
            normalizeSelectedLanguages()
            await refreshLanguageStatuses()
            isRefreshingLanguages = false
        }
    }

    func refreshLanguageStatuses() async {
        let target = language(for: targetLanguageCode)
        let availability = LanguageAvailability()
        var rows: [TranslationLanguageStatus] = []

        for option in supportedLanguages {
            if option.id == targetLanguageCode {
                rows.append(TranslationLanguageStatus(
                    id: option.id,
                    language: option,
                    state: "当前目标",
                    detail: "不能翻译到同一种语言",
                    canDownload: false
                ))
                continue
            }

            let status = await availability.status(from: option.language, to: target)
            rows.append(TranslationLanguageStatus(
                id: option.id,
                language: option,
                state: label(for: status),
                detail: detail(for: status),
                canDownload: status == .supported
            ))
        }

        languageStatuses = rows
        languageStatusMessage = "已刷新 \(rows.count) 种系统支持语言。"
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
        prepareLanguagePack(source: option.id, target: targetLanguageCode)
    }

    func prepareLanguagePack(source: String, target: String) {
        guard source != target else {
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
        if !supportedLanguages.contains(where: { $0.id == sourceLanguageCode }) {
            sourceLanguageCode = supportedLanguages.first(where: { $0.id.hasPrefix("zh") })?.id
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

    private func label(for status: LanguageAvailability.Status) -> String {
        switch status {
        case .installed: return "已安装"
        case .supported: return "可下载"
        case .unsupported: return "不支持"
        @unknown default: return "未知"
        }
    }

    private func detail(for status: LanguageAvailability.Status) -> String {
        switch status {
        case .installed: return "可以直接翻译"
        case .supported: return "需要下载系统语言包"
        case .unsupported: return "系统 Translation 不支持该语言对"
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
