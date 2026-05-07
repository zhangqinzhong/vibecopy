import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private var themeCancellable: AnyCancellable?

    init(settings: AppSettingsModel) {
        let rootView = SettingsView(settings: settings)
        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VibeCopy 设置"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.appearance = Self.appearance(for: settings.themePreference)
        window.contentViewController = hosting
        window.center()
        super.init(window: window)

        themeCancellable = settings.$themePreference
            .sink { [weak window] preference in
                window?.appearance = preference.resolvedAppearance
                window?.contentView?.needsDisplay = true
            }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func appearance(for preference: AppThemePreference) -> NSAppearance? {
        preference.resolvedAppearance
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case languages
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .appearance: return "外观"
        case .languages: return "语言"
        case .about: return "关于"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "circle.lefthalf.filled"
        case .languages: return "globe"
        case .about: return "info.circle"
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var settings: AppSettingsModel
    @State private var selectedTab: SettingsTab = .general
    private var isDark: Bool { settings.themePreference.resolvesToDark }

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Divider()

            VStack(spacing: 0) {
                Text(selectedTab.title)
                    .font(.system(size: 22, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.top, 24)
                    .padding(.bottom, 14)

                Divider()

                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(contentBackground)
        }
        .frame(minWidth: 700, minHeight: 500)
        .preferredColorScheme(settings.preferredColorScheme)
        .background(contentBackground)
        .onAppear {
            settings.refreshSupportedLanguages()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 8) {
            Spacer()
                .frame(height: 18)

            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 20)
                        Text(tab.title)
                            .font(.system(size: 14, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                    .padding(.horizontal, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedTab == tab ? Color.primary : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selectedTab == tab ? Color.primary.opacity(0.12) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(width: 210)
        .background(sidebarBackground)
    }

    private var sidebarBackground: Color {
        isDark ? Color(red: 0.03, green: 0.03, blue: 0.035) : Color(nsColor: .windowBackgroundColor).opacity(0.7)
    }

    private var contentBackground: Color {
        isDark ? Color(red: 0.02, green: 0.02, blue: 0.025) : Color(nsColor: .windowBackgroundColor)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedTab {
        case .general:
            GeneralSettingsPane(settings: settings)
        case .appearance:
            AppearanceSettingsPane(settings: settings)
        case .languages:
            LanguageSettingsPane(settings: settings)
        case .about:
            AboutSettingsPane()
        }
    }
}

private struct GeneralSettingsPane: View {
    @ObservedObject var settings: AppSettingsModel

    var body: some View {
        Form {
            Section("默认翻译方向") {
                Picker("源语言", selection: Binding(
                    get: { settings.sourceLanguageCode },
                    set: { code in
                        if let option = settings.supportedLanguages.first(where: { $0.id == code }) {
                            settings.selectSourceLanguage(option)
                        }
                    }
                )) {
                    ForEach(settings.supportedLanguages) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }

                Picker("目标语言", selection: Binding(
                    get: { settings.targetLanguageCode },
                    set: { code in
                        if let option = settings.supportedLanguages.first(where: { $0.id == code }) {
                            settings.selectTargetLanguage(option)
                        }
                    }
                )) {
                    ForEach(settings.supportedLanguages) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }

                Button("交换源语言和目标语言") {
                    settings.swapLanguages()
                }
            }

            Section("行为") {
                Text("闭合入口左侧用于翻译，右侧预留给后续剪贴板历史。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppearanceSettingsPane: View {
    @ObservedObject var settings: AppSettingsModel

    var body: some View {
        Form {
            Section("主题") {
                Picker("主题", selection: $settings.themePreference) {
                    ForEach(AppThemePreference.allCases) { preference in
                        Text(preference.label).tag(preference)
                    }
                }
                .pickerStyle(.segmented)

                Text("翻译岛和设置窗口会使用同一套主题设置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("闭合入口预览") {
                HStack(spacing: 0) {
                    IslandPetGlyph(tint: .cyan)
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.16))
                        .frame(width: 150, height: 26)
                    IslandPetGlyph(tint: .orange)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }
        }
        .formStyle(.grouped)
    }
}

private struct LanguageSettingsPane: View {
    @ObservedObject var settings: AppSettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                languageToolbar
                languageList
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .task {
            if settings.languageStatuses.isEmpty {
                settings.refreshSupportedLanguages()
            }
        }
    }

    private var languageToolbar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("系统 Translation 语言")
                .font(.headline)

            VStack(spacing: 14) {
                HStack {
                    Text(settings.languageStatusMessage)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(settings.isRefreshingLanguages ? "刷新中..." : "刷新") {
                        settings.refreshSupportedLanguages()
                    }
                    .disabled(settings.isRefreshingLanguages)
                }
            }
            .padding(14)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var languageList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("支持语言")
                .font(.headline)

            LazyVStack(spacing: 0) {
                ForEach(settings.languageStatuses) { row in
                    languageRow(row)
                    if row.id != settings.languageStatuses.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func languageRow(_ row: TranslationLanguageStatus) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.language.displayName)
                    .font(.system(size: 14, weight: .semibold))
                Text(row.language.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(row.state)
                    .font(.subheadline.weight(.semibold))
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 150, alignment: .trailing)

            if row.canDownload {
                Button(settings.isPreparingLanguagePack ? "..." : "下载") {
                    settings.prepareLanguagePack(for: row.language)
                }
                .disabled(settings.isPreparingLanguagePack)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Spacer()
                    .frame(width: 54)
            }
        }
        .padding(.vertical, 11)
    }

}

private struct AboutSettingsPane: View {
    var body: some View {
        Form {
            Section("VibeCopy") {
                Text("轻量划词、截图 OCR 与剪贴板辅助工具。")
                Text("Translation framework 语言包由 macOS 管理。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct IslandPetGlyph: View {
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let block = min(size.width, size.height) / 5
            let color = tint.opacity(0.85)
            for point in [
                CGPoint(x: 1, y: 1), CGPoint(x: 3, y: 1),
                CGPoint(x: 0, y: 2), CGPoint(x: 1, y: 2), CGPoint(x: 2, y: 2), CGPoint(x: 3, y: 2), CGPoint(x: 4, y: 2),
                CGPoint(x: 1, y: 3), CGPoint(x: 2, y: 3), CGPoint(x: 3, y: 3),
                CGPoint(x: 0, y: 4), CGPoint(x: 4, y: 4)
            ] {
                let rect = CGRect(x: point.x * block, y: point.y * block, width: block * 0.84, height: block * 0.84)
                context.fill(Path(roundedRect: rect, cornerRadius: block * 0.18), with: .color(color))
            }
        }
        .frame(width: 34, height: 28)
        .padding(.horizontal, 10)
    }
}
