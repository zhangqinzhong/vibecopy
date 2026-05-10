import AppKit
import Combine
import SwiftUI

final class ClipboardHistoryWindowController: NSWindowController {
    private let monitor: ClipboardMonitor
    private let settings: AppSettingsModel
    private let showSettingsAction: () -> Void
    private let pasteEntryAction: (ClipboardEntry) -> Void
    private var themeCancellable: AnyCancellable?
    private var keyMonitor: Any?

    init(
        monitor: ClipboardMonitor,
        settings: AppSettingsModel,
        showSettings: @escaping () -> Void,
        pasteEntry: @escaping (ClipboardEntry) -> Void
    ) {
        self.monitor = monitor
        self.settings = settings
        self.showSettingsAction = showSettings
        self.pasteEntryAction = pasteEntry
        let window = ClipboardHistoryWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "剪贴板历史"
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.minSize = NSSize(width: 420, height: 360)
        window.appearance = settings.themePreference.resolvedAppearance
        window.center()
        super.init(window: window)

        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .underWindowBackground
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.backgroundColor = NSColor.clear.cgColor
        visualEffectView.layer?.cornerRadius = 18
        visualEffectView.layer?.masksToBounds = true

        let hostingView = ClearHostingView(
            rootView: ClipboardHistoryView(
                monitor: monitor,
                settings: settings,
                showSettings: showSettings,
                pasteEntry: pasteEntry
            )
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

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            guard window?.isVisible == true, event.keyCode == 53 else { return event }
            window?.close()
            return nil
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }
}

private final class ClearHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        window?.close()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            window?.close()
            return
        }
        super.keyDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

private final class ClipboardHistoryWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            close()
            return
        }
        super.keyDown(with: event)
    }
}

private enum ClipboardFilter: String, CaseIterable, Identifiable {
    case all
    case today
    case text
    case image
    case link
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
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
    let showSettings: () -> Void
    let pasteEntry: (ClipboardEntry) -> Void
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
        .onChange(of: filteredEntries.map(\.id)) { _, ids in
            guard !ids.contains(where: { $0 == selectedEntryID }) else { return }
            selectedEntryID = nil
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(palette.icon)
                .frame(width: 28)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(palette.icon)
                TextField("输入开始搜索...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(palette.primaryText)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(.thinMaterial, in: Capsule())
            .background(palette.searchFill, in: Capsule())
            .overlay {
                Capsule().stroke(palette.glassStroke, lineWidth: 1)
            }
            .shadow(color: palette.softShadow, radius: 7, x: 0, y: 3)
            .shadow(color: palette.topHighlight, radius: 1, x: 0, y: -0.5)

            Button {
                showSettings()
            } label: {
                Image(systemName: "gearshape")
                .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(palette.icon)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help("设置")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ClipboardFilter.allCases) { filter in
                    Button {
                        selectedFilter = filter
                    } label: {
                        Text(filter.title)
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(selectedFilter == filter ? palette.accent : palette.secondaryText)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background {
                                if selectedFilter == filter {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(palette.selectedTabFill)
                                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .stroke(palette.glassStroke, lineWidth: 1)
                                        }
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 9)
        }
    }

    private var content: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 10) {
                ForEach(filteredEntries, id: \.id) { entry in
                    ClipboardEntryCard(
                        entry: entry,
                        isSelected: selectedEntryID == entry.id,
                        palette: palette,
                        selectAction: { selectedEntryID = entry.id },
                        copyAction: { copy(entry) },
                        pasteAction: { paste(entry) },
                        deleteAction: { monitor.remove(entry) }
                    )
                    .id(entry.id)
                }

                if filteredEntries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clipboard")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        Text(searchText.isEmpty ? "还没有剪贴板记录" : "没有匹配的记录")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 120)
                }
            }
            .padding(16)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()

            Text("\(filteredEntries.count) 个项目")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(palette.secondaryText)

            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(.ultraThinMaterial)
        .background(palette.footerFill)
    }

    private func copy(_ entry: ClipboardEntry) {
        selectedEntryID = entry.id
        monitor.copy(entry)
    }

    private func paste(_ entry: ClipboardEntry) {
        selectedEntryID = entry.id
        pasteEntry(entry)
    }
}

private struct ClipboardPalette {
    let theme: AppThemePreference

    var isDark: Bool { theme.resolvesToDark }
    var primaryText: Color { isDark ? Color.white.opacity(0.96) : Color.black.opacity(0.88) }
    var secondaryText: Color { isDark ? Color.white.opacity(0.7) : Color.black.opacity(0.64) }
    var icon: Color { isDark ? Color.white.opacity(0.72) : Color.black.opacity(0.54) }
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
    var softShadow: Color { Color.black.opacity(isDark ? 0.12 : 0.03) }
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
    let isSelected: Bool
    let palette: ClipboardPalette
    let selectAction: () -> Void
    let copyAction: () -> Void
    let pasteAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            preview
                .frame(width: 250, height: 58)
                .frame(maxWidth: .infinity, alignment: .center)

            VStack(alignment: .trailing, spacing: 9) {
                Text(Self.timeFormatter.string(from: entry.createdAt))
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(palette.secondaryText)

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    actionButton(systemName: "trash", action: deleteAction)
                }
                .foregroundStyle(Color.primary.opacity(0.85))
                .foregroundStyle(palette.primaryText.opacity(0.85))
            }
            .frame(width: 82, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 82)
        .background {
            ClipboardEntryClickSurface(
                singleClick: selectAction,
                doubleClick: pasteAction
            )
        }
        .background(cardBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? palette.accent : .clear, lineWidth: 2)
        }
        .shadow(color: palette.softShadow.opacity(0.18), radius: 2, x: 0, y: 1)
        .shadow(color: palette.topHighlight, radius: 1, x: 0, y: -0.5)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu {
            Button("复制") { copyAction() }
            Button("粘贴") { pasteAction() }
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
                    .font(.system(size: 20, weight: .regular))
                Text(entry.previewText)
                    .font(.system(size: 14, weight: .regular))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(palette.primaryText)
        case .link:
            VStack(alignment: .leading, spacing: 8) {
                Label("链接", systemImage: "link")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.blue)
                    .foregroundStyle(palette.accent)
                Text(entry.previewText)
                    .font(.system(size: 14, weight: .regular))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .text:
            Text(entry.previewText)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(palette.primaryText)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(palette.cardFill)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(palette.glassStroke.opacity(0.56), lineWidth: 1)
            }
    }

    private func fallbackPreview(_ text: String, systemName: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 24, weight: .regular))
            Text(text)
                .font(.system(size: 14, weight: .regular))
        }
        .foregroundStyle(palette.secondaryText)
    }

    private func actionButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .regular))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private struct ClipboardEntryClickSurface: NSViewRepresentable {
    let singleClick: () -> Void
    let doubleClick: () -> Void

    func makeNSView(context: Context) -> ClickSurfaceView {
        let view = ClickSurfaceView()
        view.singleClick = singleClick
        view.doubleClick = doubleClick
        return view
    }

    func updateNSView(_ nsView: ClickSurfaceView, context: Context) {
        nsView.singleClick = singleClick
        nsView.doubleClick = doubleClick
    }
}

private final class ClickSurfaceView: NSView {
    var singleClick: (() -> Void)?
    var doubleClick: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            doubleClick?()
        } else {
            singleClick?()
        }
    }
}

private extension ClipboardEntry {
    private static var imageCache: [UUID: NSImage] = [:]

    var image: NSImage? {
        if let cached = Self.imageCache[id] {
            return cached
        }
        guard let imageData, let image = NSImage(data: imageData) else { return nil }
        Self.imageCache[id] = image
        return image
    }
}
