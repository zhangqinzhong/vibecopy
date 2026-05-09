import AppKit
import Combine
import SwiftUI

final class ClipboardHistoryWindowController: NSWindowController {
    private let monitor: ClipboardMonitor
    private let settings: AppSettingsModel
    private var themeCancellable: AnyCancellable?

    init(monitor: ClipboardMonitor, settings: AppSettingsModel) {
        self.monitor = monitor
        self.settings = settings
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "剪贴板历史"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.minSize = NSSize(width: 560, height: 560)
        window.appearance = settings.themePreference.resolvedAppearance
        window.center()
        super.init(window: window)

        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .underWindowBackground
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.backgroundColor = NSColor.clear.cgColor

        let hostingView = ClearHostingView(
            rootView: ClipboardHistoryView(monitor: monitor, settings: settings)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(hostingView)
        window.contentView = visualEffectView

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor)
        ])

        themeCancellable = settings.$themePreference
            .sink { [weak window] preference in
                window?.appearance = preference.resolvedAppearance
            }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class ClearHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

private enum ClipboardFilter: String, CaseIterable, Identifiable {
    case all
    case pinned
    case today
    case text
    case image
    case link
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .pinned: return "📌"
        case .today: return "今天"
        case .text: return "文本"
        case .image: return "图像"
        case .link: return "链接"
        case .file: return "文件"
        }
    }
}

private struct ClipboardHistoryView: View {
    @ObservedObject var monitor: ClipboardMonitor
    @ObservedObject var settings: AppSettingsModel
    @State private var searchText = ""
    @State private var selectedFilter: ClipboardFilter = .all
    @State private var selectedEntryID: ClipboardEntry.ID?

    private var palette: ClipboardPalette {
        ClipboardPalette(theme: settings.themePreference)
    }

    private var filteredEntries: [ClipboardEntry] {
        monitor.entries.filter { entry in
            let matchesFilter: Bool = switch selectedFilter {
            case .all:
                true
            case .pinned:
                entry.isPinned
            case .today:
                Calendar.current.isDateInToday(entry.createdAt)
            case .text:
                entry.kind == .text
            case .image:
                entry.kind == .image
            case .link:
                entry.kind == .link
            case .file:
                entry.kind == .file
            }

            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return matchesFilter }
            return matchesFilter && entry.previewText.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            filterBar
            Divider()
                .overlay(palette.divider)
            content
            footer
        }
        .background(ClipboardGlassBackground(palette: palette))
        .preferredColorScheme(settings.preferredColorScheme)
        .onAppear {
            if selectedEntryID == nil {
                selectedEntryID = filteredEntries.first?.id
            }
        }
        .onChange(of: filteredEntries.map(\.id)) { _, ids in
            guard !ids.contains(where: { $0 == selectedEntryID }) else { return }
            selectedEntryID = ids.first
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(palette.icon)
                .frame(width: 40)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(palette.icon)
                TextField("输入开始搜索...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(palette.primaryText)
            }
            .padding(.horizontal, 15)
            .frame(height: 44)
            .background(.thinMaterial, in: Capsule())
            .background(palette.searchFill, in: Capsule())
            .overlay {
                Capsule().stroke(palette.glassStroke, lineWidth: 1)
            }
            .shadow(color: palette.softShadow, radius: 7, x: 0, y: 3)
            .shadow(color: palette.topHighlight, radius: 1, x: 0, y: -0.5)

            Button {
            } label: {
                Image(systemName: "gearshape")
                .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(palette.icon)
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .help("设置")
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(ClipboardFilter.allCases) { filter in
                    Button {
                        selectedFilter = filter
                    } label: {
                        Text(filter.title)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(selectedFilter == filter ? palette.accent : palette.secondaryText)
                            .padding(.horizontal, filter == .pinned ? 14 : 16)
                            .frame(height: 38)
                            .background {
                                if selectedFilter == filter {
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .fill(palette.selectedTabFill)
                                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                                .stroke(palette.glassStroke, lineWidth: 1)
                                        }
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 13)
        }
    }

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { index, entry in
                        ClipboardEntryCard(
                            entry: entry,
                            shortcutIndex: index < 9 ? index + 1 : nil,
                            isSelected: selectedEntryID == entry.id,
                            palette: palette,
                            copyAction: { copy(entry) },
                            pinAction: { monitor.togglePin(entry) },
                            deleteAction: { monitor.remove(entry) }
                        )
                        .id(entry.id)
                        .onTapGesture {
                            selectedEntryID = entry.id
                        }
                        .onTapGesture(count: 2) {
                            copy(entry)
                        }
                    }

                    if filteredEntries.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "clipboard")
                                .font(.system(size: 42))
                                .foregroundStyle(.secondary)
                            Text(searchText.isEmpty ? "还没有剪贴板记录" : "没有匹配的记录")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 120)
                    }
                }
                .padding(24)
            }
            .onChange(of: selectedEntryID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()

            Text("\(filteredEntries.count) 个项目")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(palette.secondaryText)

            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(height: 48)
        .background(.ultraThinMaterial)
        .background(palette.footerFill)
    }

    private func copy(_ entry: ClipboardEntry) {
        selectedEntryID = entry.id
        monitor.copy(entry)
    }
}

private struct ClipboardPalette {
    let theme: AppThemePreference

    var isDark: Bool { theme.resolvesToDark }
    var primaryText: Color { isDark ? Color.white.opacity(0.9) : Color.black.opacity(0.82) }
    var secondaryText: Color { isDark ? Color.white.opacity(0.62) : Color.black.opacity(0.58) }
    var icon: Color { isDark ? Color.white.opacity(0.62) : Color.black.opacity(0.46) }
    var accent: Color { isDark ? Color(red: 0.34, green: 0.72, blue: 1) : Color(red: 0.02, green: 0.44, blue: 0.98) }
    var divider: Color { isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.08) }
    var glassStroke: Color { isDark ? Color.white.opacity(0.16) : Color.white.opacity(0.64) }
    var searchFill: Color { isDark ? Color.white.opacity(0.08) : Color.white.opacity(0.24) }
    var footerFill: Color { isDark ? Color.black.opacity(0.12) : Color.white.opacity(0.18) }
    var cardFill: Color { isDark ? Color.black.opacity(0.22) : Color.white.opacity(0.24) }
    var selectedCardFill: Color { isDark ? Color.white.opacity(0.1) : Color.white.opacity(0.4) }
    var selectedTabFill: Color { isDark ? Color(red: 0.13, green: 0.35, blue: 0.72).opacity(0.5) : Color(red: 0.58, green: 0.75, blue: 1).opacity(0.5) }
    var backgroundTintTop: Color { isDark ? Color(red: 0.06, green: 0.1, blue: 0.14).opacity(0.38) : Color(red: 0.76, green: 0.91, blue: 1).opacity(0.28) }
    var backgroundTintBottom: Color { isDark ? Color(red: 0.02, green: 0.05, blue: 0.08).opacity(0.42) : Color(red: 0.68, green: 0.88, blue: 1).opacity(0.22) }
    var softShadow: Color { Color.black.opacity(isDark ? 0.22 : 0.05) }
    var topHighlight: Color { Color.white.opacity(isDark ? 0.1 : 0.45) }
}

private struct ClipboardGlassBackground: View {
    let palette: ClipboardPalette

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    palette.backgroundTintTop,
                    Color.clear,
                    palette.backgroundTintBottom
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Rectangle()
                .fill(palette.isDark ? Color.black.opacity(0.1) : Color.white.opacity(0.08))
        }
        .ignoresSafeArea()
    }
}

private struct ClipboardEntryCard: View {
    let entry: ClipboardEntry
    let shortcutIndex: Int?
    let isSelected: Bool
    let palette: ClipboardPalette
    let copyAction: () -> Void
    let pinAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            preview
                .frame(width: 330, height: 82)
                .frame(maxWidth: .infinity, alignment: .center)

            VStack(alignment: .trailing, spacing: 14) {
                Text(Self.timeFormatter.string(from: entry.createdAt))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(palette.secondaryText)

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    if let shortcutIndex {
                        Text("⌘ \(shortcutIndex)")
                            .font(.system(size: 20, weight: .medium))
                    }
                    actionButton(systemName: entry.isPinned ? "pin.fill" : "pin", action: pinAction)
                    actionButton(systemName: "trash", action: deleteAction)
                }
                .foregroundStyle(Color.primary.opacity(0.85))
                .foregroundStyle(palette.primaryText.opacity(0.85))
            }
            .frame(width: 100, alignment: .trailing)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 15)
        .frame(minHeight: 112)
        .background(cardBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(isSelected ? palette.accent : .clear, lineWidth: 3)
        }
        .shadow(color: palette.softShadow.opacity(isSelected ? 1 : 0.62), radius: isSelected ? 18 : 10, x: 0, y: isSelected ? 9 : 5)
        .shadow(color: palette.topHighlight, radius: 1, x: 0, y: -0.5)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            if let shortcutIndex {
                Button {
                    copyAction()
                } label: {
                    EmptyView()
                }
                .keyboardShortcut(KeyEquivalent(Character("\(shortcutIndex)")), modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
            }
        }
        .contextMenu {
            Button("复制") { copyAction() }
            Button(entry.isPinned ? "取消固定" : "固定") { pinAction() }
            Button("删除") { deleteAction() }
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch entry.kind {
        case .image:
            if let nsImage = entry.image {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                fallbackPreview("图片", systemName: "photo")
            }
        case .file:
            VStack(spacing: 8) {
                Image(systemName: "doc")
                    .font(.system(size: 24, weight: .medium))
                Text(entry.previewText)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(palette.primaryText)
        case .link:
            VStack(alignment: .leading, spacing: 8) {
                Label("链接", systemImage: "link")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.blue)
                    .foregroundStyle(palette.accent)
                Text(entry.previewText)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .text:
            Text(entry.previewText)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(palette.primaryText)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(isSelected ? palette.selectedCardFill : palette.cardFill)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(palette.glassStroke.opacity(isSelected ? 1 : 0.72), lineWidth: 1)
            }
    }

    private func fallbackPreview(_ text: String, systemName: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 30, weight: .medium))
            Text(text)
                .font(.system(size: 16, weight: .medium))
        }
        .foregroundStyle(palette.secondaryText)
    }

    private func actionButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private extension ClipboardEntry {
    var image: NSImage? {
        guard let imageData else { return nil }
        return NSImage(data: imageData)
    }
}
