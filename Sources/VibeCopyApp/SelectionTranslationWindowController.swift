import AppKit
import AVFoundation
import Combine
import SwiftUI

final class SelectionTranslationWindowController: NSWindowController {
    private static let islandSize = NSSize(width: 600, height: 360)
    private static let externalClosedIslandSize = NSSize(width: 246, height: 28)
    private static let notchedClosedSideExpansion: CGFloat = 56
    private static let hoverOpenDelay: TimeInterval = 0.12

    private let translationService: TranslationService
    private let settings: AppSettingsModel
    private let showSettingsAction: () -> Void
    private let islandModel = TranslationIslandModel()
    private weak var hostingView: NSView?
    private var lastSourceText = ""
    private var lastTranslatedText = ""
    private var sourceLanguage: String { settings.sourceLanguageCode }
    private var targetLanguage: String { settings.targetLanguageCode }
    private var manualTranslationGeneration = 0
    private var isPinned = false
    private var localEventMonitor: Any?
    private var globalMouseMonitor: Any?
    private var hoverOpenWorkItem: DispatchWorkItem?
    private var transitionGeneration = 0
    private var scheduledTranslation: DispatchWorkItem?
    private var themeCancellable: AnyCancellable?
    private let speechSynthesizer = AVSpeechSynthesizer()

    var isIslandVisible: Bool {
        window?.isVisible == true
    }

    init(
        translationService: TranslationService,
        settings: AppSettingsModel,
        showSettings: @escaping () -> Void
    ) {
        self.translationService = translationService
        self.settings = settings
        self.showSettingsAction = showSettings

        let window = TranslationIslandPanel(
            contentRect: NSRect(origin: .zero, size: Self.islandSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = "划词翻译"
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.alphaValue = 1
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true

        super.init(window: window)

        setupNativeView()
        syncModelFromSettings()
        window.appearance = Self.appearance(for: settings.themePreference)
        themeCancellable = settings.$themePreference
            .sink { [weak self, weak window] preference in
                self?.islandModel.themePreference = preference
                window?.appearance = preference.resolvedAppearance
            }
        positionAtIsland()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        scheduledTranslation?.cancel()
        stopInteractionMonitoring()
    }

    func showLoading(sourceText: String) {
        scheduledTranslation?.cancel()
        lastSourceText = sourceText
        lastTranslatedText = ""
        syncModelFromSettings()
        render(
            mode: .loading,
            sourceText: sourceText,
            translatedText: "",
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
        presentIsland()
    }

    func show(result: TranslationResult) {
        scheduledTranslation?.cancel()
        lastSourceText = result.sourceText
        lastTranslatedText = result.translatedText
        syncModelFromSettings()
        render(
            mode: .result,
            sourceText: result.sourceText,
            translatedText: result.translatedText,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
        presentIsland()
    }

    func showNoSelection() {
        scheduledTranslation?.cancel()
        lastSourceText = ""
        lastTranslatedText = ""
        render(
            mode: .empty,
            sourceText: "",
            translatedText: "",
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
        presentIsland()
    }

    func dismissIsland() {
        guard let window, window.isVisible else { return }
        transitionGeneration &+= 1
        let generation = transitionGeneration
        hoverOpenWorkItem?.cancel()
        hoverOpenWorkItem = nil
        islandModel.closedSize = Self.closedIslandSize(for: Self.targetScreen())
        window.ignoresMouseEvents = true
        islandModel.phase = .closed

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak window] in
            guard let self, let window, self.transitionGeneration == generation else { return }
            window.orderFrontRegardless()
        }
    }

    private func setupNativeView() {
        guard let contentView = window?.contentView else { return }

        let actions = TranslationIslandActions(
            sourceTextChanged: { [weak self] text in self?.sourceTextChanged(text) },
            copySource: { [weak self] in self?.copy(self?.lastSourceText ?? "") },
            copyResult: { [weak self] in
                guard let self else { return }
                self.copy(self.lastTranslatedText.isEmpty ? self.lastSourceText : self.lastTranslatedText)
            },
            copyCamel: { [weak self] in
                guard let self else { return }
                self.copy(Self.identifierText(from: self.lastTranslatedText.isEmpty ? self.lastSourceText : self.lastTranslatedText, style: .camel))
            },
            copySnake: { [weak self] in
                guard let self else { return }
                self.copy(Self.identifierText(from: self.lastTranslatedText.isEmpty ? self.lastSourceText : self.lastTranslatedText, style: .snake))
            },
            speakSource: { [weak self] in self?.speak(self?.lastSourceText ?? "") },
            speakResult: { [weak self] in
                guard let self else { return }
                self.speak(self.lastTranslatedText.isEmpty ? self.lastSourceText : self.lastTranslatedText)
            },
            swapLanguages: { [weak self] in self?.swapLanguages() },
            togglePin: { [weak self] in self?.togglePin() },
            showSettings: { [weak self] in self?.showSettingsAction() },
            selectSourceLanguage: { [weak self] option in self?.selectSourceLanguage(option) },
            selectTargetLanguage: { [weak self] option in self?.selectTargetLanguage(option) },
            dismiss: { [weak self] in self?.dismissIsland() }
        )

        let hostingView = TranslationIslandHostingView(
            rootView: TranslationIslandView(model: islandModel, settings: settings, actions: actions)
        )
        hostingView.controller = self
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.addSubview(hostingView)
        self.hostingView = hostingView

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    private func render(
        mode: TranslationMode,
        sourceText: String,
        translatedText: String,
        sourceLanguage: String,
        targetLanguage: String
    ) {
        syncModelFromSettings()
        islandModel.mode = mode
        islandModel.sourceText = sourceText
        islandModel.translatedText = translatedText
        islandModel.sourceLanguage = sourceLanguage
        islandModel.targetLanguage = targetLanguage
    }

    private func sourceTextChanged(_ text: String) {
        lastSourceText = text
        islandModel.sourceText = text
        scheduledTranslation?.cancel()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            manualTranslationGeneration &+= 1
            lastTranslatedText = ""
            islandModel.mode = .empty
            islandModel.translatedText = ""
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.translateTypedText(text, sourceLanguage: self?.sourceLanguage, targetLanguage: self?.targetLanguage)
        }
        scheduledTranslation = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: workItem)
    }

    private func translateTypedText(_ text: String, sourceLanguage: String?, targetLanguage: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lastSourceText = text
        guard !trimmed.isEmpty else {
            manualTranslationGeneration &+= 1
            lastTranslatedText = ""
            render(
                mode: .empty,
                sourceText: "",
                translatedText: "",
                sourceLanguage: self.sourceLanguage,
                targetLanguage: self.targetLanguage
            )
            return
        }

        if let sourceLanguage { settings.sourceLanguageCode = sourceLanguage }
        if let targetLanguage { settings.targetLanguageCode = targetLanguage }
        syncModelFromSettings()

        manualTranslationGeneration &+= 1
        let generation = manualTranslationGeneration
        lastTranslatedText = ""
        render(
            mode: .loading,
            sourceText: text,
            translatedText: "",
            sourceLanguage: self.sourceLanguage,
            targetLanguage: self.targetLanguage
        )

        translationService.translate(
            trimmed,
            sourceLanguage: self.sourceLanguage,
            targetLanguage: self.targetLanguage
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.manualTranslationGeneration == generation else { return }
                self.lastSourceText = result.sourceText
                self.lastTranslatedText = result.translatedText
                self.render(
                    mode: .result,
                    sourceText: self.lastSourceText,
                    translatedText: result.translatedText,
                    sourceLanguage: self.sourceLanguage,
                    targetLanguage: self.targetLanguage
                )
            }
        }
    }

    private func swapLanguages() {
        settings.swapLanguages()
        syncModelFromSettings()
        translateTypedText(lastSourceText, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
    }

    private func selectSourceLanguage(_ option: TranslationLanguageOption) {
        settings.selectSourceLanguage(option)
        syncModelFromSettings()
        translateTypedText(lastSourceText, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
    }

    private func selectTargetLanguage(_ option: TranslationLanguageOption) {
        settings.selectTargetLanguage(option)
        syncModelFromSettings()
        translateTypedText(lastSourceText, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
    }

    private func togglePin() {
        isPinned.toggle()
        islandModel.isPinned = isPinned
        window?.level = isPinned ? .screenSaver : .statusBar
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func speak(_ text: String) {
        let spokenText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spokenText.isEmpty else { return }

        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        speechSynthesizer.speak(AVSpeechUtterance(string: spokenText))
    }

    private func syncModelFromSettings() {
        islandModel.sourceLanguage = settings.sourceLanguageCode
        islandModel.targetLanguage = settings.targetLanguageCode
        islandModel.themePreference = settings.themePreference
    }

    private static func appearance(for preference: AppThemePreference) -> NSAppearance? {
        preference.resolvedAppearance
    }

    private func presentIsland() {
        guard let window else { return }
        let finalFrame = islandFrame()
        let isFirstOpen = !window.isVisible
        let shouldAnimateOpen = isFirstOpen || islandModel.phase == .closed
        transitionGeneration &+= 1
        let generation = transitionGeneration
        islandModel.closedSize = Self.closedIslandSize(for: Self.targetScreen())
        window.setFrame(finalFrame, display: false)
        window.ignoresMouseEvents = false

        if shouldAnimateOpen {
            if isFirstOpen {
                islandModel.phase = .closed
            }
            window.alphaValue = 1
            window.orderFrontRegardless()
            window.makeKey()
            startInteractionMonitoring()

            DispatchQueue.main.async { [weak self] in
                guard let self, self.transitionGeneration == generation else { return }
                self.islandModel.phase = .opening
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
                    guard let self, self.transitionGeneration == generation else { return }
                    self.islandModel.phase = .opened
                }
            }
        } else {
            if islandModel.phase != .opened {
                islandModel.phase = .opened
            }
            window.orderFrontRegardless()
            window.makeKey()
            startInteractionMonitoring()
        }
    }

    private func positionAtIsland() {
        window?.setFrame(islandFrame(), display: true)
    }

    private func islandFrame() -> NSRect {
        let screen = Self.targetScreen()
        guard let screen else {
            return NSRect(origin: .zero, size: Self.islandSize)
        }

        let modeTopInset: CGFloat = Self.isNotched(screen) ? 0 : 10
        return NSRect(
            x: screen.frame.midX - Self.islandSize.width / 2,
            y: screen.frame.maxY - Self.islandSize.height - modeTopInset,
            width: Self.islandSize.width,
            height: Self.islandSize.height
        )
    }

    private func startInteractionMonitoring() {
        if localEventMonitor == nil {
            localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved, .leftMouseDown]) { [weak self] event in
                guard let self else { return event }

                if event.type == .keyDown && event.keyCode == 53 {
                    self.dismissIsland()
                    return nil
                }

                if event.type == .mouseMoved {
                    self.handleMouseMoved(at: NSEvent.mouseLocation)
                } else if event.type == .leftMouseDown {
                    self.handleMouseDown(at: NSEvent.mouseLocation)
                }

                return event
            }
        }

        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
                guard let self else { return }
                if event.type == .mouseMoved {
                    self.handleMouseMoved(at: NSEvent.mouseLocation)
                } else if event.type == .leftMouseDown {
                    self.handleMouseDown(at: NSEvent.mouseLocation)
                }
            }
        }
    }

    private func stopInteractionMonitoring() {
        hoverOpenWorkItem?.cancel()
        hoverOpenWorkItem = nil

        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }

        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func handleMouseMoved(at screenPoint: NSPoint) {
        guard window?.isVisible == true else { return }

        if islandModel.phase == .closed, closedIslandRect().contains(screenPoint) {
            scheduleHoverOpen()
            return
        }

        if islandModel.phase == .closed {
            hoverOpenWorkItem?.cancel()
            hoverOpenWorkItem = nil
            return
        }

        if islandModel.phase == .opened, !openedIslandRect().contains(screenPoint) {
            dismissIsland()
        }
    }

    private func handleMouseDown(at screenPoint: NSPoint) {
        guard window?.isVisible == true else { return }

        if islandModel.phase == .closed {
            if closedIslandRect().contains(screenPoint) {
                hoverOpenWorkItem?.cancel()
                hoverOpenWorkItem = nil
                presentIsland()
            }
            return
        }

        if islandModel.phase == .opened, !openedIslandRect().contains(screenPoint) {
            dismissIsland()
        }
    }

    private func scheduleHoverOpen() {
        guard hoverOpenWorkItem == nil else { return }

        let item = DispatchWorkItem { [weak self] in
            guard let self, self.islandModel.phase == .closed else { return }
            self.hoverOpenWorkItem = nil
            self.presentIsland()
        }

        hoverOpenWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverOpenDelay, execute: item)
    }

    private func closedIslandRect() -> NSRect {
        guard let window else { return .zero }
        let closedSize = islandModel.closedSize
        return NSRect(
            x: window.frame.midX - closedSize.width / 2,
            y: window.frame.maxY - closedSize.height,
            width: closedSize.width,
            height: closedSize.height
        )
    }

    private func openedIslandRect() -> NSRect {
        window?.frame ?? .zero
    }

    private static func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: isNotched) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private static func closedIslandSize(for screen: NSScreen?) -> CGSize {
        guard let screen else {
            return externalClosedIslandSize
        }

        guard isNotched(screen) else {
            return externalClosedIslandSize
        }

        let notchSize = screen.notchSize
        return CGSize(
            width: notchSize.width + notchedClosedSideExpansion,
            height: max(24, notchSize.height)
        )
    }

    private static func isNotched(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0 ||
            screen.auxiliaryTopLeftArea?.isEmpty == false ||
            screen.auxiliaryTopRightArea?.isEmpty == false
    }

    private static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value)) ||
                (0x3400...0x4DBF).contains(Int(scalar.value))
        }
    }

    private enum IdentifierStyle {
        case camel
        case snake
    }

    private static func identifierText(from text: String, style: IdentifierStyle) -> String {
        let words = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return text }

        switch style {
        case .camel:
            let first = words[0].lowercased()
            let rest = words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            return ([first] + rest).joined()
        case .snake:
            return words.map { $0.lowercased() }.joined(separator: "_")
        }
    }
}

private final class TranslationIslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class TranslationIslandHostingView<Content: View>: NSHostingView<Content> {
    weak var controller: SelectionTranslationWindowController?

    override var isOpaque: Bool {
        false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }
}

private enum TranslationMode {
    case empty
    case loading
    case result
}

private enum TranslationIslandPhase {
    case closed
    case opening
    case opened
}

private let translationIslandOpenAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
private let translationIslandCloseAnimation = Animation.smooth(duration: 0.3)

private struct TranslationPalette {
    let theme: AppThemePreference

    var isDark: Bool { theme.resolvesToDark }
    var ink: Color { isDark ? Color(red: 0.91, green: 0.94, blue: 0.96) : Color(red: 0.08, green: 0.09, blue: 0.11) }
    var muted: Color { isDark ? Color(red: 0.62, green: 0.66, blue: 0.7) : Color(red: 0.38, green: 0.4, blue: 0.42) }
    var cyan: Color { Color(red: 0.07, green: 0.75, blue: 0.82) }
    var placeholder: Color { isDark ? Color.white.opacity(0.18) : Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.22) }
    var surfaceTop: Color { isDark ? Color.black : .white }
    var surfaceMiddle: Color { isDark ? Color.black : Color(red: 0.97, green: 0.98, blue: 0.99) }
    var surfaceBottom: Color { isDark ? Color.black : .white }
    var buttonFill: Color { isDark ? Color(red: 0.055, green: 0.055, blue: 0.065) : .white }
    var highlight: Color { isDark ? Color.white.opacity(0.06) : .white }
    var rimOpacity: Double { isDark ? 0.05 : 0.72 }
    var secondaryRimOpacity: Double { isDark ? 0 : 0.035 }
    var glowOpacity: Double { isDark ? 0 : 1 }
    var shadow: Color { .black }
}

private final class TranslationIslandModel: ObservableObject {
    @Published var phase: TranslationIslandPhase = .closed
    @Published var mode: TranslationMode = .empty
    @Published var sourceText = ""
    @Published var translatedText = ""
    @Published var sourceLanguage = "zh_CN"
    @Published var targetLanguage = "en_US"
    @Published var isPinned = false
    @Published var closedSize = CGSize(width: 246, height: 28)
    @Published var themePreference: AppThemePreference = .system
}

private struct TranslationIslandActions {
    var sourceTextChanged: (String) -> Void
    var copySource: () -> Void
    var copyResult: () -> Void
    var copyCamel: () -> Void
    var copySnake: () -> Void
    var speakSource: () -> Void
    var speakResult: () -> Void
    var swapLanguages: () -> Void
    var togglePin: () -> Void
    var showSettings: () -> Void
    var selectSourceLanguage: (TranslationLanguageOption) -> Void
    var selectTargetLanguage: (TranslationLanguageOption) -> Void
    var dismiss: () -> Void
}

private struct TranslationIslandView: View {
    @ObservedObject var model: TranslationIslandModel
    @ObservedObject var settings: AppSettingsModel
    let actions: TranslationIslandActions

    private let openedSize = CGSize(width: 600, height: 360)
    private let openedContentHorizontalInset: CGFloat = 24

    private var usesOpenedSurface: Bool {
        model.phase != .closed
    }

    private var showsOpenedContent: Bool {
        model.phase == .opened
    }

    private var panelAnimation: Animation {
        usesOpenedSurface ? translationIslandOpenAnimation : translationIslandCloseAnimation
    }

    private var currentSurfaceSize: CGSize {
        usesOpenedSurface ? openedSize : model.closedSize
    }

    private var surfaceShape: TranslationIslandShape {
        TranslationIslandShape(
            topRadius: usesOpenedSurface ? 20 : 6,
            bottomRadius: usesOpenedSurface ? 32 : 18
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear

            ZStack(alignment: .top) {
                islandSurface

                if !usesOpenedSurface {
                    HStack(spacing: 0) {
                        MiniIslandPetGlyph(tint: palette.cyan)
                        Spacer(minLength: 0)
                        MiniIslandPetGlyph(tint: Color.orange)
                    }
                    .frame(width: max(0, model.closedSize.width - 18), height: model.closedSize.height)
                    .padding(.top, max(0, (model.closedSize.height - 24) / 2))
                    .allowsHitTesting(false)
                }

                TranslationIslandContent(model: model, settings: settings, actions: actions)
                    .frame(
                        width: openedSize.width - openedContentHorizontalInset * 2,
                        height: openedSize.height
                    )
                    .opacity(showsOpenedContent ? 1 : 0)
                    .blur(radius: showsOpenedContent ? 0 : 5)
                    .scaleEffect(showsOpenedContent ? 1 : 0.985, anchor: .top)
                    .offset(y: showsOpenedContent ? 0 : -8)
                    .allowsHitTesting(showsOpenedContent)
                    .animation(.easeOut(duration: 0.16).delay(0.08), value: showsOpenedContent)
            }
            .frame(
                width: currentSurfaceSize.width,
                height: currentSurfaceSize.height,
                alignment: .top
            )
            .scaleEffect(usesOpenedSurface ? 1 : 0.98, anchor: .top)
            .clipShape(surfaceShape)
            .overlay {
                surfaceShape
                    .stroke(Color.white.opacity(palette.rimOpacity), lineWidth: 1)
            }
            .overlay {
                surfaceShape
                    .stroke(Color.black.opacity(palette.secondaryRimOpacity), lineWidth: 0.5)
            }
        }
        .frame(width: openedSize.width, height: openedSize.height, alignment: .top)
        .animation(panelAnimation, value: model.phase)
        .preferredColorScheme(settings.preferredColorScheme)
    }

    private var palette: TranslationPalette {
        TranslationPalette(theme: model.themePreference)
    }

    private var islandSurface: some View {
        ZStack {
            surfaceShape
            .fill(.ultraThinMaterial)
            .shadow(color: palette.shadow.opacity(usesOpenedSurface ? 0.075 : 0.065), radius: usesOpenedSurface ? 36 : 16, x: 0, y: usesOpenedSurface ? 22 : 9)
            .shadow(color: palette.shadow.opacity(usesOpenedSurface ? 0.035 : 0.03), radius: usesOpenedSurface ? 9 : 5, x: 0, y: usesOpenedSurface ? 5 : 2)

            surfaceShape
            .fill(
                LinearGradient(
                    colors: [
                        palette.surfaceTop.opacity(usesOpenedSurface ? 0.98 : 1),
                        palette.surfaceMiddle.opacity(usesOpenedSurface ? 0.98 : 1),
                        palette.surfaceBottom.opacity(usesOpenedSurface ? 0.98 : 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            surfaceShape
            .fill(
                RadialGradient(
                    colors: [
                        Color.white.opacity((usesOpenedSurface ? 0.48 : 0.36) * palette.glowOpacity),
                        Color.white.opacity(0)
                    ],
                    center: .topLeading,
                    startRadius: 8,
                    endRadius: usesOpenedSurface ? 280 : 120
                )
            )

            DotField()
                .opacity(usesOpenedSurface ? 0.18 : 0.08)
                .mask(
                    LinearGradient(
                        colors: [.black, .black.opacity(0.1), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }
}

private struct TranslationIslandContent: View {
    @ObservedObject var model: TranslationIslandModel
    @ObservedObject var settings: AppSettingsModel
    let actions: TranslationIslandActions

    private var palette: TranslationPalette {
        TranslationPalette(theme: model.themePreference)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .frame(height: 30)
                .padding(.top, 10)

            TranslationPane(
                language: settings.languageLabel(for: model.sourceLanguage),
                languageColor: palette.ink,
                text: sourceBinding,
                placeholder: "输入文本",
                isSource: true,
                mode: model.mode,
                palette: palette,
                languageOptions: settings.supportedLanguages,
                selectedLanguageCode: model.sourceLanguage,
                selectLanguage: actions.selectSourceLanguage,
                actions: [
                    TranslationActionButton(systemName: "speaker.wave.2", action: actions.speakSource),
                    TranslationActionButton(systemName: "doc.on.doc", action: actions.copySource)
                ]
            )
            .frame(height: 118)
            .padding(.top, 8)

            divider
                .frame(height: 46)

            TranslationPane(
                language: settings.languageLabel(for: model.targetLanguage),
                languageColor: palette.cyan,
                text: .constant(resultText),
                placeholder: "Enter text",
                isSource: false,
                mode: model.mode,
                palette: palette,
                languageOptions: settings.supportedLanguages,
                selectedLanguageCode: model.targetLanguage,
                selectLanguage: actions.selectTargetLanguage,
                actions: [
                    TranslationActionButton(systemName: "speaker.wave.2", action: actions.speakResult),
                    TranslationActionButton(systemName: "doc.on.doc", action: actions.copyResult),
                    TranslationActionButton(text: "Aa", action: actions.copyCamel),
                    TranslationActionButton(systemName: "minus.square", action: actions.copySnake)
                ]
            )
            .frame(height: 122)
            .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }

    private var toolbar: some View {
        HStack(spacing: 18) {
            TranslationActionButton(systemName: "pin", isActive: model.isPinned, action: actions.togglePin)
            Spacer()
            TranslationActionButton(systemName: "star", action: {})
            TranslationActionButton(systemName: "viewfinder", action: {})
            TranslationActionButton(systemName: "gearshape", action: actions.showSettings)
        }
    }

    private var divider: some View {
        ZStack(alignment: .center) {
            HStack(spacing: 54) {
                TranslationDividerLine()
                TranslationDividerLine()
            }
            .padding(.horizontal, 10)

            Button(action: actions.swapLanguages) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(palette.cyan)
                    .frame(width: 42, height: 42)
                    .background(
                        Circle()
                            .fill(palette.buttonFill.opacity(0.92))
                            .shadow(color: palette.shadow.opacity(0.13), radius: 10, x: 0, y: 5)
                            .shadow(color: palette.highlight.opacity(0.85), radius: 5, x: 0, y: -1)
                    )
                    .overlay(
                        Circle()
                            .stroke(palette.shadow.opacity(0.055), lineWidth: 0.75)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var sourceBinding: Binding<String> {
        Binding(
            get: { model.sourceText },
            set: { actions.sourceTextChanged($0) }
        )
    }

    private var resultText: String {
        if model.mode == .loading {
            return "Translating..."
        }
        if model.mode == .result, !model.translatedText.isEmpty {
            return model.translatedText
        }
        return ""
    }

}

private struct TranslationPane: View {
    let language: String
    let languageColor: Color
    @Binding var text: String
    let placeholder: String
    let isSource: Bool
    let mode: TranslationMode
    let palette: TranslationPalette
    let languageOptions: [TranslationLanguageOption]
    let selectedLanguageCode: String
    let selectLanguage: (TranslationLanguageOption) -> Void
    let actions: [TranslationActionButton]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                ForEach(languageOptions) { option in
                    Button {
                        selectLanguage(option)
                    } label: {
                        if option.id == selectedLanguageCode {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(language)
                        .font(.system(size: 19, weight: .bold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(languageColor)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            ZStack(alignment: .topLeading) {
                if isSource {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 38, weight: .bold))
                            .foregroundStyle(palette.placeholder)
                            .allowsHitTesting(false)
                    }
                    BoundedTextInput(text: $text, fontSize: 38, palette: palette)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .clipped()
                } else {
                    Text(displayText)
                        .font(.system(size: text.isEmpty ? 38 : 34, weight: .bold))
                        .foregroundStyle(text.isEmpty ? palette.cyan.opacity(0.3) : palette.ink.opacity(mode == .loading ? 0.48 : 0.9))
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: 50, alignment: .topLeading)
            .clipped()

            HStack(spacing: 20) {
                ForEach(actions.indices, id: \.self) { index in
                    actions[index]
                }
            }
        }
    }

    private var displayText: String {
        text.isEmpty ? placeholder : text
    }
}

private struct TranslationActionButton: View {
    var systemName: String?
    var text: String?
    var isActive = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: 18, weight: .medium))
                } else if let text {
                    Text(text)
                        .font(.system(size: 13, weight: .bold))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(lineWidth: 1.5)
                                .frame(width: 23, height: 21)
                        )
                }
            }
            .foregroundStyle(isActive ? Color(red: 0.07, green: 0.75, blue: 0.82) : Color.secondary)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TranslationDividerLine: View {
    var body: some View {
        ZStack(alignment: .center) {
            Rectangle()
                .fill(Color.black.opacity(0.15))
                .frame(height: 1.2)

            Rectangle()
                .fill(Color.white.opacity(0.55))
                .frame(height: 0.8)
                .offset(y: -0.75)

            Rectangle()
                .fill(Color.black.opacity(0.035))
                .frame(height: 0.7)
                .offset(y: 1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 4)
    }
}

private struct BoundedTextInput: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let palette: TranslationPalette

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.drawsBackground = false
        scrollView.clipsToBounds = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.maximumNumberOfLines = 2
        textView.font = .systemFont(ofSize: fontSize, weight: .bold)
        textView.textColor = NSColor(palette.ink)
        textView.insertionPointColor = NSColor(palette.ink)
        textView.string = text

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text, !context.coordinator.isEditingMarkedText {
            textView.string = text
        }
        textView.font = .systemFont(ofSize: fontSize, weight: .bold)
        textView.textColor = NSColor(palette.ink)
        textView.insertionPointColor = NSColor(palette.ink)
        textView.textContainer?.containerSize = NSSize(
            width: max(0, scrollView.contentSize.width),
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        weak var textView: NSTextView?
        var isEditingMarkedText = false

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            isEditingMarkedText = textView.hasMarkedText()
            guard !isEditingMarkedText else { return }
            text = textView.string
        }

        func textDidEndEditing(_ notification: Notification) {
            isEditingMarkedText = false
            if let textView = notification.object as? NSTextView {
                text = textView.string
            }
        }
    }
}

private struct MiniIslandPetGlyph: View {
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let block = min(size.width, size.height) / 5
            for point in [
                CGPoint(x: 1, y: 1), CGPoint(x: 3, y: 1),
                CGPoint(x: 0, y: 2), CGPoint(x: 1, y: 2), CGPoint(x: 2, y: 2), CGPoint(x: 3, y: 2), CGPoint(x: 4, y: 2),
                CGPoint(x: 1, y: 3), CGPoint(x: 2, y: 3), CGPoint(x: 3, y: 3),
                CGPoint(x: 0, y: 4), CGPoint(x: 4, y: 4)
            ] {
                let rect = CGRect(x: point.x * block, y: point.y * block, width: block * 0.78, height: block * 0.78)
                context.fill(Path(roundedRect: rect, cornerRadius: block * 0.16), with: .color(tint.opacity(0.72)))
            }
        }
        .frame(width: 22, height: 22)
    }
}

private struct TranslationIslandShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = min(topRadius, rect.width / 4, rect.height / 4)
        let bottom = min(bottomRadius, rect.width / 4, rect.height / 2)
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control: CGPoint(x: rect.minX + top, y: rect.minY)
        )

        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + top, y: rect.maxY)
        )

        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - top, y: rect.maxY)
        )

        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY)
        )

        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))

        path.closeSubpath()

        return path
    }
}

private struct DotField: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 13
            let radius: CGFloat = 1.25
            var y: CGFloat = 8
            while y < size.height * 0.62 {
                var x: CGFloat = 8
                while x < size.width - 8 {
                    let rect = CGRect(x: x, y: y, width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(Color.black.opacity(0.075)))
                    x += spacing
                }
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

private extension NSScreen {
    static let translationExternalNotchSize = CGSize(width: 190, height: 38)

    var notchSize: CGSize {
        guard safeAreaInsets.top > 0 else {
            return Self.translationExternalNotchSize
        }

        let leftPadding = auxiliaryTopLeftArea?.width ?? 0
        let rightPadding = auxiliaryTopRightArea?.width ?? 0
        let notchWidth = frame.width - leftPadding - rightPadding + 4
        return CGSize(width: notchWidth, height: safeAreaInsets.top)
    }
}
