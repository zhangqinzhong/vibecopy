import AppKit
import Carbon
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
        window.setFrameAutosaveName("")
        window.appearance = Self.appearance(for: settings.themePreference)
        window.contentViewController = hosting
        Self.applyCenteredFrame(to: window, display: false)
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

    func showCentered() {
        guard let window else { return }
        Self.applyCenteredFrame(to: window, display: false)
        window.orderFrontRegardless()
        window.makeKey()
    }

    private static func applyCenteredFrame(to window: NSWindow, display: Bool) {
        let screen = NSScreen.main ?? window.screen ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else {
            window.center()
            return
        }

        var frame = window.frame
        frame.origin = NSPoint(
            x: visibleFrame.midX - frame.size.width / 2,
            y: visibleFrame.midY - frame.size.height / 2
        )
        window.setFrame(frame, display: display)
    }

    private static func appearance(for preference: AppThemePreference) -> NSAppearance? {
        preference.resolvedAppearance
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case shortcuts
    case appearance
    case languages
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .shortcuts: return "快捷键"
        case .appearance: return "外观"
        case .languages: return "语言"
        case .about: return "关于"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
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
        case .shortcuts:
            ShortcutSettingsPane(settings: settings)
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

private struct ShortcutSettingsPane: View {
    @ObservedObject var settings: AppSettingsModel
    @State private var isRecording = false
    @State private var validationMessage: String?

    var body: some View {
        Form {
            Section("划词翻译") {
                Toggle("启用全局快捷键", isOn: $settings.selectionHotKeyEnabled)

                HStack {
                    Text("快捷键")
                    Spacer()
                    HotKeyRecorderButton(
                        hotKey: settings.selectionHotKey,
                        isRecording: $isRecording,
                        validationMessage: $validationMessage
                    ) { keyCode, modifiers in
                        settings.setSelectionHotKey(keyCode: keyCode, modifiers: modifiers)
                    }
                }

                Text(settings.selectionHotKeyStatusMessage)
                    .font(.caption)
                    .foregroundStyle(settings.selectionHotKeyHasConflict ? .red : .secondary)

                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text("在任意 App 中选中文本后按设置的快捷键，VibeCopy 会读取选区并打开翻译岛。当前版本使用自动方向：中文转英文，非中文转简体中文。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct HotKeyRecorderButton: View {
    let hotKey: HotKeyConfiguration
    @Binding var isRecording: Bool
    @Binding var validationMessage: String?
    var onChange: (UInt32, UInt32) -> Void
    @State private var localMonitor: Any?

    var body: some View {
        Button {
            validationMessage = nil
            isRecording = true
            startRecording()
        } label: {
            Text(isRecording ? "按下新的快捷键..." : hotKey.displayName)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(isRecording ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onChange(of: isRecording) { _, isRecording in
            if !isRecording {
                stopRecording()
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        stopRecording()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = carbonModifiers(from: event.modifierFlags)
            guard modifiers != 0 else {
                validationMessage = "快捷键需要包含 Command、Option、Control 或 Shift。"
                isRecording = false
                return nil
            }
            validationMessage = nil
            onChange(UInt32(event.keyCode), modifiers)
            isRecording = false
            return nil
        }
    }

    private func stopRecording() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(NSEvent.ModifierFlags.command.rawValue) }
        if flags.contains(.option) { modifiers |= UInt32(NSEvent.ModifierFlags.option.rawValue) }
        if flags.contains(.control) { modifiers |= UInt32(NSEvent.ModifierFlags.control.rawValue) }
        if flags.contains(.shift) { modifiers |= UInt32(NSEvent.ModifierFlags.shift.rawValue) }
        return modifiers
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
    private var paneBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

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
        .background(paneBackground)
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
                        .lineLimit(2)
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
                ForEach(Array(settings.languageStatuses.enumerated()), id: \.element.id) { index, row in
                    languageRow(row)
                    if index != settings.languageStatuses.indices.last {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 16)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func languageRow(_ row: TranslationLanguageStatus) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.language.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(row.language.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(statusTitle(for: row))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)
            }
            .frame(width: 138, alignment: .trailing)

            if row.canDownload {
                Button(settings.isPreparingLanguagePack ? "..." : "下载") {
                    settings.prepareLanguagePack(for: row.language)
                }
                .disabled(settings.isPreparingLanguagePack)
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(red: 0.18, green: 0.42, blue: 0.82))
                )
            } else {
                Text(row.state)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(row.state == "已下载" ? Color.green : Color.secondary)
                    .frame(width: 64, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(row.state == "已下载" ? Color.green.opacity(0.18) : Color.primary.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(row.state == "已下载" ? Color.green.opacity(0.35) : Color.primary.opacity(0.12), lineWidth: 1)
                    )
            }
        }
        .padding(.vertical, 12)
    }

    private func statusTitle(for row: TranslationLanguageStatus) -> String {
        row.canDownload ? row.state : ""
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
