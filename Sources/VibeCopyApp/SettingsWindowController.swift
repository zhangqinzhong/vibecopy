import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController {
    init(settings: AppSettingsModel) {
        let rootView = SettingsView(settings: settings)
            .preferredColorScheme(settings.preferredColorScheme)
        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VibeCopy 设置"
        window.contentViewController = hosting
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.icon)
                        .tag(tab)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            detailView
        }
        .frame(minWidth: 700, minHeight: 500)
        .preferredColorScheme(settings.preferredColorScheme)
        .onAppear {
            settings.refreshSupportedLanguages()
        }
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
        .navigationTitle("通用")
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
        .navigationTitle("外观")
    }
}

private struct LanguageSettingsPane: View {
    @ObservedObject var settings: AppSettingsModel

    var body: some View {
        Form {
            Section("系统 Translation 语言") {
                HStack {
                    Text(settings.languageStatusMessage)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(settings.isRefreshingLanguages ? "刷新中..." : "刷新") {
                        settings.refreshSupportedLanguages()
                    }
                    .disabled(settings.isRefreshingLanguages)
                }

                Button(settings.isPreparingLanguagePack ? "准备中..." : "下载当前语言方向的语言包") {
                    settings.prepareSelectedLanguagePack()
                }
                .disabled(settings.isPreparingLanguagePack)
            }

            Section("支持语言") {
                ForEach(settings.languageStatuses) { row in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.language.displayName)
                            Text(row.language.id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(row.state)
                                .font(.subheadline.weight(.semibold))
                            Text(row.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("语言")
        .task {
            if settings.languageStatuses.isEmpty {
                settings.refreshSupportedLanguages()
            }
        }
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
        .navigationTitle("关于")
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
