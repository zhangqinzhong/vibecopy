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
    private let clipboardMonitor: ClipboardMonitor
    private let showSettingsAction: () -> Void
    private let showClipboardAction: () -> Void
    private let islandModel = TranslationIslandModel()
    private weak var hostingView: NSView?
    private var lastSourceText = ""
    private var lastTranslatedText = ""
    private var currentSourceLanguage: String
    private var currentTargetLanguage: String
    private var sourceLanguage: String { currentSourceLanguage }
    private var targetLanguage: String { currentTargetLanguage }
    private var manualTranslationGeneration = 0
    private var isPinned = false
    private var localEventMonitor: Any?
    private var globalMouseMonitor: Any?
    private var hoverOpenWorkItem: DispatchWorkItem?
    private var hoverClipboardWorkItem: DispatchWorkItem?
    private var transitionGeneration = 0
    private var scheduledTranslation: DispatchWorkItem?
    private var themeCancellable: AnyCancellable?
    private var hasPointerEnteredOpenedIsland = false
    private let speechSynthesizer = AVSpeechSynthesizer()

    var isIslandVisible: Bool {
        window?.isVisible == true
    }

    init(
        translationService: TranslationService,
        settings: AppSettingsModel,
        clipboardMonitor: ClipboardMonitor,
        showSettings: @escaping () -> Void,
        showClipboard: @escaping () -> Void
    ) {
        self.translationService = translationService
        self.settings = settings
        self.clipboardMonitor = clipboardMonitor
        self.showSettingsAction = showSettings
        self.showClipboardAction = showClipboard
        self.currentSourceLanguage = settings.sourceLanguageCode
        self.currentTargetLanguage = settings.targetLanguageCode

        let window = TranslationIslandPanel(
            contentRect: NSRect(origin: .zero, size: Self.islandSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = "划词翻译"
        window.titleVisibility = .hidden
        window.isMovable = false
        window.isMovableByWindowBackground = false
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
        syncModelFromCurrentDirection()
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
        showLoading(sourceText: sourceText, sourceLanguage: settings.sourceLanguageCode, targetLanguage: settings.targetLanguageCode)
    }

    func showLoading(sourceText: String, sourceLanguage: String, targetLanguage: String) {
        scheduledTranslation?.cancel()
        currentSourceLanguage = sourceLanguage
        currentTargetLanguage = targetLanguage
        lastSourceText = sourceText
        lastTranslatedText = ""
        syncModelFromCurrentDirection()
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
        syncModelFromCurrentDirection()
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
        resetDirectionFromDefaults()
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

    func dismissIsland(respectingPin: Bool = false) {
        guard let window, window.isVisible else { return }
        guard !respectingPin || !isPinned else { return }
        transitionGeneration &+= 1
        let generation = transitionGeneration
        hoverOpenWorkItem?.cancel()
        hoverOpenWorkItem = nil
        hoverClipboardWorkItem?.cancel()
        hoverClipboardWorkItem = nil
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
            submitSourceText: { [weak self] in self?.submitSourceText() },
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
            dismiss: { [weak self] in self?.dismissIsland() },
            copyClipboardEntry: { [weak self] entry in self?.copyClipboardEntry(entry) },
            deleteClipboardEntry: { [weak self] entry in self?.deleteClipboardEntry(entry) },
            clipboardSearchChanged: { [weak self] text in self?.islandModel.clipboardSearchText = text }
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
        syncModelFromCurrentDirection()
        islandModel.mode = mode
        islandModel.sourceText = sourceText
        islandModel.translatedText = translatedText
        islandModel.sourceLanguage = sourceLanguage
        islandModel.targetLanguage = targetLanguage
    }

    private func sourceTextChanged(_ text: String) {
        guard text != lastSourceText || text != islandModel.sourceText else { return }
        lastSourceText = text
        islandModel.sourceText = text
        scheduledTranslation?.cancel()
        manualTranslationGeneration &+= 1

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastTranslatedText = ""
            islandModel.mode = .empty
            islandModel.translatedText = ""
            return
        }

        lastTranslatedText = ""
        islandModel.mode = .empty
        islandModel.translatedText = ""
    }

    private func submitSourceText() {
        translateTypedText(lastSourceText, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
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

        if let sourceLanguage { currentSourceLanguage = sourceLanguage }
        if let targetLanguage { currentTargetLanguage = targetLanguage }
        syncModelFromCurrentDirection()

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
                self.lastSourceText = text
                self.lastTranslatedText = result.translatedText
                self.render(
                    mode: .result,
                    sourceText: text,
                    translatedText: result.translatedText,
                    sourceLanguage: self.sourceLanguage,
                    targetLanguage: self.targetLanguage
                )
            }
        }
    }

    private func swapLanguages() {
        let previousSourceText = lastSourceText
        let previousTranslatedText = lastTranslatedText
        swap(&currentSourceLanguage, &currentTargetLanguage)
        syncModelFromCurrentDirection()

        guard !previousTranslatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            translateTypedText(previousSourceText, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
            return
        }

        scheduledTranslation?.cancel()
        manualTranslationGeneration &+= 1
        lastSourceText = previousTranslatedText
        lastTranslatedText = previousSourceText
        render(
            mode: .result,
            sourceText: previousTranslatedText,
            translatedText: previousSourceText,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
    }

    private func selectSourceLanguage(_ option: TranslationLanguageOption) {
        guard option.id != currentTargetLanguage else { return }
        currentSourceLanguage = option.id
        syncModelFromCurrentDirection()
        translateTypedText(lastSourceText, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
    }

    private func selectTargetLanguage(_ option: TranslationLanguageOption) {
        guard option.id != currentSourceLanguage else { return }
        currentTargetLanguage = option.id
        syncModelFromCurrentDirection()
        translateTypedText(lastSourceText, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
    }

    private func togglePin() {
        isPinned.toggle()
        islandModel.isPinned = isPinned
        window?.level = isPinned ? .screenSaver : .statusBar
    }

    private func copyClipboardEntry(_ entry: ClipboardEntry) {
        clipboardMonitor.copy(entry)
    }

    private func deleteClipboardEntry(_ entry: ClipboardEntry) {
        clipboardMonitor.remove(entry)
        islandModel.clipboardEntries = clipboardMonitor.entries
    }

    private func deleteClipboardEntryWithReplacement(_ entry: ClipboardEntry) {
        let entries = islandModel.filteredClipboardEntries()
        var nextID: ClipboardEntry.ID?
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            let nextIndex = entries.index(after: index)
            if nextIndex < entries.endIndex {
                nextID = entries[nextIndex].id
            } else if index > entries.startIndex {
                nextID = entries[entries.index(before: index)].id
            }
        }
        clipboardMonitor.remove(entry)
        islandModel.clipboardEntries = clipboardMonitor.entries
        islandModel.clipboardSelectedID = nextID
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

    private func resetDirectionFromDefaults() {
        currentSourceLanguage = settings.sourceLanguageCode
        currentTargetLanguage = settings.targetLanguageCode
    }

    private func syncModelFromCurrentDirection() {
        islandModel.sourceLanguage = currentSourceLanguage
        islandModel.targetLanguage = currentTargetLanguage
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
        hasPointerEnteredOpenedIsland = openedIslandRect().contains(NSEvent.mouseLocation)
        islandModel.closedSize = Self.closedIslandSize(for: Self.targetScreen())
        window.setFrame(finalFrame, display: false)
        window.ignoresMouseEvents = false

        if shouldAnimateOpen {
            if isFirstOpen {
                islandModel.phase = .closed
            }
            window.alphaValue = 1
            window.orderFrontRegardless()
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
            localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved]) { [weak self] event in
                guard let self else { return event }

                if event.type == .keyDown && event.keyCode == 53 {
                    if self.islandModel.phase == .opened {
                        self.dismissIsland()
                        return nil
                    }
                    return event
                }

                if event.type == .keyDown,
                   self.islandModel.phase == .opened,
                   self.islandModel.activePanel == .clipboard {
                    switch event.keyCode {
                    case 125:
                        self.islandModel.navigateClipboardSelection(direction: 1)
                        return nil
                    case 126:
                        self.islandModel.navigateClipboardSelection(direction: -1)
                        return nil
                    case 51, 117:
                        if let id = self.islandModel.clipboardSelectedID,
                           let entry = self.islandModel.clipboardEntries.first(where: { $0.id == id }) {
                            self.deleteClipboardEntryWithReplacement(entry)
                        }
                        return nil
                    default:
                        break
                    }
                }

                if event.type == .mouseMoved {
                    self.handleMouseMoved(at: NSEvent.mouseLocation)
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
        hoverClipboardWorkItem?.cancel()
        hoverClipboardWorkItem = nil

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

        if islandModel.phase == .closed {
            switch closedIslandSide(at: screenPoint) {
            case .translation:
                scheduleHoverOpen()
                hoverClipboardWorkItem?.cancel()
                hoverClipboardWorkItem = nil
                return
            case .clipboard:
                scheduleHoverClipboard()
                hoverOpenWorkItem?.cancel()
                hoverOpenWorkItem = nil
                return
            case nil:
                hoverOpenWorkItem?.cancel()
                hoverOpenWorkItem = nil
                hoverClipboardWorkItem?.cancel()
                hoverClipboardWorkItem = nil
                return
            }
        }

        if islandModel.phase == .opened, openedIslandRect().contains(screenPoint) {
            hasPointerEnteredOpenedIsland = true
            return
        }

        if islandModel.phase == .opened, hasPointerEnteredOpenedIsland {
            dismissIsland(respectingPin: true)
        }
    }

    private func handleMouseDown(at screenPoint: NSPoint) {
        guard window?.isVisible == true else { return }

        if islandModel.phase == .closed {
            if let side = closedIslandSide(at: screenPoint) {
                hoverOpenWorkItem?.cancel()
                hoverOpenWorkItem = nil
                hoverClipboardWorkItem?.cancel()
                hoverClipboardWorkItem = nil
                switch side {
                case .translation:
                    presentIsland()
                case .clipboard:
                    presentClipboardIsland()
                }
            }
            return
        }

        if islandModel.phase == .opened, !openedIslandRect().contains(screenPoint) {
            dismissIsland(respectingPin: true)
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

    private func scheduleHoverClipboard() {
        guard hoverClipboardWorkItem == nil else { return }

        let item = DispatchWorkItem { [weak self] in
            guard let self, self.islandModel.phase == .closed else { return }
            self.hoverClipboardWorkItem = nil
            self.presentClipboardIsland()
        }

        hoverClipboardWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverOpenDelay, execute: item)
    }

    private func presentClipboardIsland() {
        islandModel.activePanel = .clipboard
        islandModel.clipboardEntries = clipboardMonitor.entries
        islandModel.clipboardSearchText = ""
        islandModel.clipboardSelectedID = nil
        islandModel.mode = .empty
        presentIsland()
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

    private func closedIslandSide(at screenPoint: NSPoint) -> ClosedIslandSide? {
        let rect = closedIslandRect()
        guard rect.contains(screenPoint) else { return nil }
        return screenPoint.x < rect.midX ? .translation : .clipboard
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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let chars = event.charactersIgnoringModifiers?.lowercased()
        else { return super.performKeyEquivalent(with: event) }

        let sel: Selector
        switch chars {
        case "c": sel = #selector(NSTextView.copy(_:))
        case "v": sel = #selector(NSTextView.paste(_:))
        case "x": sel = #selector(NSTextView.cut(_:))
        case "a": sel = #selector(NSTextView.selectAll(_:))
        default: return super.performKeyEquivalent(with: event)
        }
        NSApp.sendAction(sel, to: nil, from: self)
        return true
    }
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

private enum ClosedIslandSide {
    case translation
    case clipboard
}

private let translationIslandOpenAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
private let translationIslandCloseAnimation = Animation.smooth(duration: 0.3)
private let miniIslandGlyphSize: CGFloat = 22

private struct TranslationPalette {
    let theme: AppThemePreference

    var isDark: Bool { theme.resolvesToDark }
    var ink: Color { isDark ? Color(red: 0.88, green: 0.91, blue: 0.94) : Color(red: 0.08, green: 0.09, blue: 0.11) }
    var muted: Color { isDark ? Color(red: 0.62, green: 0.67, blue: 0.72) : Color(red: 0.38, green: 0.4, blue: 0.42) }
    var cyan: Color { Color(red: 0.07, green: 0.75, blue: 0.82) }
    var placeholder: Color { isDark ? Color.white.opacity(0.15) : Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.22) }
    var surfaceTop: Color { isDark ? Color(red: 0.17, green: 0.21, blue: 0.25) : .white }
    var surfaceMiddle: Color { isDark ? Color(red: 0.12, green: 0.16, blue: 0.19) : Color(red: 0.97, green: 0.98, blue: 0.99) }
    var surfaceBottom: Color { isDark ? Color(red: 0.08, green: 0.11, blue: 0.14) : .white }
    var surfaceOpacity: Double { isDark ? 0.68 : 0.98 }
    var buttonFill: Color { isDark ? Color(red: 0.1, green: 0.13, blue: 0.16) : .white }
    var highlight: Color { isDark ? Color.white.opacity(0.12) : .white }
    var rimOpacity: Double { isDark ? 0.16 : 0.72 }
    var secondaryRimOpacity: Double { isDark ? 0.08 : 0.035 }
    var glowOpacity: Double { isDark ? 0.28 : 1 }
    var shadow: Color { .black }
}

private struct TranslationPaletteKey: EnvironmentKey {
    static let defaultValue = TranslationPalette(theme: .system)
}

private extension EnvironmentValues {
    var translationPalette: TranslationPalette {
        get { self[TranslationPaletteKey.self] }
        set { self[TranslationPaletteKey.self] = newValue }
    }
}

private enum IslandPanel {
    case translation
    case clipboard
}

private final class TranslationIslandModel: ObservableObject {
    @Published var phase: TranslationIslandPhase = .closed
    @Published var mode: TranslationMode = .empty
    @Published var sourceText = ""
    @Published var translatedText = ""
    @Published var sourceLanguage = "zh-Hans"
    @Published var targetLanguage = "en-US"
    @Published var isPinned = false
    @Published var closedSize = CGSize(width: 246, height: 28)
    @Published var themePreference: AppThemePreference = .system
    @Published var activePanel: IslandPanel = .translation
    @Published var clipboardSearchText = ""
    @Published var clipboardEntries: [ClipboardEntry] = []
    @Published var clipboardSelectedID: ClipboardEntry.ID?

    func filteredClipboardEntries() -> [ClipboardEntry] {
        let query = clipboardSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return clipboardEntries }
        return clipboardEntries.filter { $0.previewText.localizedCaseInsensitiveContains(query) }
    }

    func navigateClipboardSelection(direction: Int) {
        let entries = filteredClipboardEntries()
        guard !entries.isEmpty else { return }

        if let currentID = clipboardSelectedID,
           let currentIndex = entries.firstIndex(where: { $0.id == currentID }) {
            let nextIndex = currentIndex + direction
            if nextIndex >= 0, nextIndex < entries.count {
                clipboardSelectedID = entries[nextIndex].id
            } else if direction < 0 {
                clipboardSelectedID = entries.last?.id
            } else {
                clipboardSelectedID = entries.first?.id
            }
        } else {
            clipboardSelectedID = direction > 0 ? entries.first?.id : entries.last?.id
        }
    }
}

private struct TranslationIslandActions {
    var sourceTextChanged: (String) -> Void
    var submitSourceText: () -> Void
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
    var copyClipboardEntry: (ClipboardEntry) -> Void
    var deleteClipboardEntry: (ClipboardEntry) -> Void
    var clipboardSearchChanged: (String) -> Void
}

private struct PaneActionItem {
    var systemName: String?
    var text: String?
    var action: () -> Void
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
        let palette = TranslationPalette(theme: model.themePreference)
        ZStack(alignment: .top) {
            Color.clear

            ZStack(alignment: .top) {
                islandSurface(palette: palette)

                if !usesOpenedSurface {
                    HStack(spacing: 0) {
                        MiniIslandPetGlyph(kind: .translation, tint: palette.cyan, size: miniIslandGlyphSize)
                        Spacer(minLength: 0)
                        MiniIslandPetGlyph(kind: .clipboard, tint: Color.orange, size: miniIslandGlyphSize)
                    }
                    .frame(width: max(0, model.closedSize.width - 14), height: model.closedSize.height, alignment: .center)
                    .allowsHitTesting(false)
                }

                if showsOpenedContent, model.activePanel == .translation {
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

                if showsOpenedContent, model.activePanel == .clipboard {
                    ClipboardIslandContent(model: model, settings: settings, actions: actions)
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
        .environment(\.translationPalette, palette)
    }

    private func islandSurface(palette: TranslationPalette) -> some View {
        ZStack {
            surfaceShape
            .fill(.ultraThinMaterial)
            .shadow(color: palette.shadow.opacity(usesOpenedSurface ? 0.075 : 0.065), radius: usesOpenedSurface ? 36 : 16, x: 0, y: usesOpenedSurface ? 22 : 9)
            .shadow(color: palette.shadow.opacity(usesOpenedSurface ? 0.035 : 0.03), radius: usesOpenedSurface ? 9 : 5, x: 0, y: usesOpenedSurface ? 5 : 2)

            surfaceShape
            .fill(
                LinearGradient(
                    colors: [
                        palette.surfaceTop.opacity(usesOpenedSurface ? palette.surfaceOpacity : min(1, palette.surfaceOpacity + 0.14)),
                        palette.surfaceMiddle.opacity(usesOpenedSurface ? palette.surfaceOpacity : min(1, palette.surfaceOpacity + 0.14)),
                        palette.surfaceBottom.opacity(usesOpenedSurface ? palette.surfaceOpacity : min(1, palette.surfaceOpacity + 0.14))
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

    @Environment(\.translationPalette) private var palette

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: 34)

                TranslationPane(
                    language: settings.languageLabel(for: model.sourceLanguage),
                    languageColor: palette.ink,
                    text: sourceBinding,
                    placeholder: "输入文本",
                    isSource: true,
                    mode: model.mode,
                    languageOptions: settings.supportedLanguages,
                    selectedLanguageCode: model.sourceLanguage,
                    selectLanguage: actions.selectSourceLanguage,
                    textAreaHeight: 58,
                    submitAction: actions.submitSourceText,
                    actions: [
                        PaneActionItem(systemName: "speaker.wave.2", action: actions.speakSource),
                        PaneActionItem(systemName: "doc.on.doc", action: actions.copySource)
                    ]
                )
                .frame(height: 112)
                .padding(.top, 2)

                divider
                    .frame(height: 36)

                TranslationPane(
                    language: settings.languageLabel(for: model.targetLanguage),
                    languageColor: palette.cyan,
                    text: .constant(resultText),
                    placeholder: "Enter text",
                    isSource: false,
                    mode: model.mode,
                    languageOptions: settings.supportedLanguages,
                    selectedLanguageCode: model.targetLanguage,
                    selectLanguage: actions.selectTargetLanguage,
                    textAreaHeight: 62,
                    submitAction: nil,
                    actions: [
                        PaneActionItem(systemName: "speaker.wave.2", action: actions.speakResult),
                        PaneActionItem(systemName: "doc.on.doc", action: actions.copyResult),
                        PaneActionItem(text: "Aa", action: actions.copyCamel),
                        PaneActionItem(systemName: "minus.square", action: actions.copySnake)
                    ]
                )
                .frame(height: 116)
                .padding(.top, 2)
            }

            toolbar
                .frame(height: 28)
                .scaleEffect(0.9)
                .offset(y: -22)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private var toolbar: some View {
        HStack(spacing: 18) {
            TranslationActionButton(systemName: "pin", isActive: model.isPinned, palette: palette, action: actions.togglePin)
                .offset(x: -28)
            Spacer()
            HStack(spacing: 18) {
                TranslationActionButton(systemName: "star", palette: palette, action: {})
                TranslationActionButton(systemName: "viewfinder", palette: palette, action: {})
                TranslationActionButton(systemName: "gearshape", palette: palette, action: actions.showSettings)
            }
            .offset(x: 28)
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
    let languageOptions: [TranslationLanguageOption]
    let selectedLanguageCode: String
    let selectLanguage: (TranslationLanguageOption) -> Void
    let textAreaHeight: CGFloat
    let submitAction: (() -> Void)?
    let actions: [PaneActionItem]

    @Environment(\.translationPalette) private var palette
    @State private var isEditingSourceText = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
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
                        .font(.system(size: 18, weight: .bold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(languageColor)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            ZStack(alignment: .topLeading) {
                if isSource {
                    if text.isEmpty && !isEditingSourceText {
                        Text(placeholder)
                            .font(.system(size: displayFontSize, weight: .bold))
                            .foregroundStyle(palette.placeholder)
                            .allowsHitTesting(false)
                    }
                    BoundedTextInput(
                        text: $text,
                        isEditing: $isEditingSourceText,
                        fontSize: displayFontSize,
                        palette: palette,
                        onSubmit: { submitAction?() }
                    )
                        .frame(maxWidth: .infinity)
                        .frame(height: textAreaHeight)
                        .padding(.trailing, showsSubmitButton ? 56 : 0)
                        .clipped()

                    if showsSubmitButton, let submitAction {
                        TranslationSubmitButton(
                            isLoading: mode == .loading,
                            palette: palette,
                            action: submitAction
                        )
                        .disabled(mode == .loading)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, 4)
                    }
                } else {
                    TranslationTextDisplay(
                        text: displayText,
                        fontSize: displayFontSize,
                        foregroundColor: text.isEmpty ? palette.cyan.opacity(0.3) : palette.ink.opacity(mode == .loading ? 0.48 : 0.9)
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: textAreaHeight, alignment: .topLeading)
            .clipped()

            HStack(spacing: 20) {
                ForEach(actions.indices, id: \.self) { index in
                    TranslationActionButton(
                        systemName: actions[index].systemName,
                        text: actions[index].text,
                        palette: palette,
                        action: actions[index].action
                    )
                }
            }
            .frame(height: 28, alignment: .center)
        }
    }

    private var displayText: String {
        text.isEmpty ? placeholder : text
    }

    private var displayFontSize: CGFloat {
        if text.isEmpty { return isSource ? 32 : 31 }
        if text.count > 120 { return 21 }
        if text.count > 56 { return 26 }
        return isSource ? 32 : 31
    }

    private var showsSubmitButton: Bool {
        isSource && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct ClipboardIslandContent: View {
    @ObservedObject var model: TranslationIslandModel
    @ObservedObject var settings: AppSettingsModel
    let actions: TranslationIslandActions
    @Environment(\.translationPalette) private var palette

    @State private var selectedFilter: ClipboardFilter = .all

    private var filteredEntries: [ClipboardEntry] {
        let base: [ClipboardEntry] = switch selectedFilter {
        case .all: model.clipboardEntries
        case .today: model.clipboardEntries.filter { Calendar.current.isDateInToday($0.createdAt) }
        case .text: model.clipboardEntries.filter { $0.kind == .text }
        case .image: model.clipboardEntries.filter { $0.kind == .image }
        case .link: model.clipboardEntries.filter { $0.kind == .link }
        case .file: model.clipboardEntries.filter { $0.kind == .file }
        }
        let query = model.clipboardSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        return base.filter { $0.previewText.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Color.clear.frame(height: 34)

                HStack(spacing: 16) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(palette.muted)
                        .frame(width: 28)

                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(palette.muted)
                        TextField("搜索剪贴板...", text: $model.clipboardSearchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(palette.ink)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(.thinMaterial, in: Capsule())
                    .overlay {
                        Capsule().stroke(palette.muted.opacity(0.15), lineWidth: 1)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 8)

                filterBar
                Divider().overlay(palette.muted.opacity(0.12))
                content
                footer
            }

            toolbar
                .frame(height: 28)
                .scaleEffect(0.9)
                .offset(y: -22)
        }
        .padding(.horizontal, 24)
    }

    private var toolbar: some View {
        HStack(spacing: 18) {
            TranslationActionButton(systemName: "pin", isActive: model.isPinned, palette: palette, action: actions.togglePin)
                .offset(x: -28)
            Spacer()
            HStack(spacing: 18) {
                TranslationActionButton(systemName: "gearshape", palette: palette, action: actions.showSettings)
            }
            .offset(x: 28)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach([ClipboardFilter.today, .text, .image, .link]) { filter in
                Button {
                    selectedFilter = filter
                } label: {
                    Text(filter.title)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(selectedFilter == filter ? palette.cyan : palette.muted)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background {
                            if selectedFilter == filter {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(palette.cyan.opacity(0.14))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(palette.cyan.opacity(0.3), lineWidth: 1)
                                    }
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 8)
    }

    private var content: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 10) {
                ForEach(filteredEntries, id: \.id) { entry in
                    ClipboardIslandEntryRow(
                        entry: entry,
                        isSelected: model.clipboardSelectedID == entry.id,
                        palette: palette,
                        selectAction: { model.clipboardSelectedID = entry.id },
                        copyAction: { copyEntry(entry) },
                        deleteAction: { deleteEntry(entry) }
                    )
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .scale(scale: 0.98).combined(with: .opacity)
                    ))
                }

                if filteredEntries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clipboard")
                            .font(.system(size: 36)).foregroundStyle(palette.muted)
                        Text(model.clipboardSearchText.isEmpty ? "剪贴板为空" : "无匹配记录")
                            .font(.system(size: 16)).foregroundStyle(palette.muted)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 50)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .animation(.easeOut(duration: 0.18), value: filteredEntries.map(\.id))
        }
    }

    private var footer: some View {
        HStack {
            Text("\(filteredEntries.count) 条记录")
                .font(.system(size: 12)).foregroundStyle(palette.muted)
            Spacer()
        }
        .padding(.horizontal, 28).padding(.bottom, 10)
    }

    private func copyEntry(_ entry: ClipboardEntry) {
        model.clipboardSelectedID = entry.id
        actions.copyClipboardEntry(entry)
    }

    private func deleteEntry(_ entry: ClipboardEntry) {
        let nextID = replacementSelection(afterDeleting: entry)
        withAnimation(.easeOut(duration: 0.18)) {
            model.clipboardSelectedID = nextID
            actions.deleteClipboardEntry(entry)
        }
    }

    private func replacementSelection(afterDeleting entry: ClipboardEntry) -> ClipboardEntry.ID? {
        let entries = filteredEntries
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return nil }
        let nextIndex = entries.index(after: index)
        if nextIndex < entries.endIndex { return entries[nextIndex].id }
        if index > entries.startIndex { return entries[entries.index(before: index)].id }
        return nil
    }
}

private enum ClipboardFilter: String, CaseIterable, Identifiable {
    case all, today, text, image, link, file
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "全部"
        case .today: "今天"
        case .text: "文本"
        case .image: "图像"
        case .link: "链接"
        case .file: "文件"
        }
    }
}

private struct ClipboardIslandEntryRow: View {
    let entry: ClipboardEntry
    let isSelected: Bool
    let palette: TranslationPalette
    let selectAction: () -> Void
    let copyAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                preview
                    .frame(maxWidth: .infinity, alignment: .leading)

                ClipboardEntryClickSurface(
                    singleClick: selectAction,
                    doubleClick: copyAction,
                    delete: deleteAction
                )
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 58)

            Text(timeString)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(palette.muted)
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 58)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.buttonFill.opacity(0.55))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? palette.cyan : .clear, lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu {
            Button("拷贝") { copyAction() }
            Button("删除") { deleteAction() }
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch entry.kind {
        case .image:
            if let nsImage = entry.image {
                Image(nsImage: nsImage)
                    .resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Label("图片", systemImage: "photo").foregroundStyle(palette.muted)
            }
        case .file:
            Label(entry.previewText, systemImage: "doc")
                .font(.system(size: 13)).lineLimit(1).foregroundStyle(palette.ink)
        case .link:
            Label(entry.previewText, systemImage: "link")
                .font(.system(size: 13)).lineLimit(1).foregroundStyle(Color.blue)
        case .text:
            Text(entry.previewText)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(palette.ink).lineLimit(2)
        }
    }

    private var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: entry.createdAt)
    }
}

// ClickSurface for clipboard island — mirrors ClickSurfaceView from ClipboardHistoryWindowController
private struct ClipboardEntryClickSurface: NSViewRepresentable {
    let singleClick: () -> Void
    let doubleClick: () -> Void
    let delete: () -> Void

    func makeNSView(context: Context) -> ClipboardClickSurfaceView {
        let view = ClipboardClickSurfaceView()
        view.singleClick = singleClick
        view.doubleClick = doubleClick
        view.deleteAction = delete
        return view
    }

    func updateNSView(_ nsView: ClipboardClickSurfaceView, context: Context) {
        nsView.singleClick = singleClick
        nsView.doubleClick = doubleClick
        nsView.deleteAction = delete
    }
}

private final class ClipboardClickSurfaceView: NSView {
    var singleClick: (() -> Void)?
    var doubleClick: (() -> Void)?
    var deleteAction: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount >= 2 {
            doubleClick?()
        } else {
            singleClick?()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: deleteAction?()
        default: super.keyDown(with: event)
        }
    }
}

private extension ClipboardEntry {
    private static var islandImageCache: [UUID: NSImage] = [:]

    var image: NSImage? {
        if let cached = Self.islandImageCache[id] { return cached }
        guard let imageData, let img = NSImage(data: imageData) else { return nil }
        Self.islandImageCache[id] = img
        return img
    }
}

private struct TranslationSubmitButton: View {
    let isLoading: Bool
    let palette: TranslationPalette
    let action: () -> Void
    @State private var isAcknowledging = false

    var body: some View {
        Button {
            action()
            withAnimation(.easeOut(duration: 0.08)) {
                isAcknowledging = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                withAnimation(.easeOut(duration: 0.14)) {
                    isAcknowledging = false
                }
            }
        } label: {
            ZStack {
                if isAcknowledging {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(palette.cyan.opacity(0.16))
                        .frame(width: 38, height: 38)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(palette.cyan.opacity(0.35), lineWidth: 1)
                        )
                }

                TranslationSubmitGlyph(isLoading: isLoading, palette: palette)
            }
            .frame(width: 42, height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(TranslationActionButtonStyle())
    }
}

private struct TranslationSubmitGlyph: View {
    let isLoading: Bool
    let palette: TranslationPalette

    var body: some View {
        ZStack {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(palette.muted.opacity(0.65))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(palette.cyan, lineWidth: 2.3)
                        .frame(width: 22, height: 24)
                        .offset(x: 5, y: 3)

                    UnevenRoundedRectangle(
                        topLeadingRadius: 5,
                        bottomLeadingRadius: 5,
                        bottomTrailingRadius: 1.5,
                        topTrailingRadius: 1.5,
                        style: .continuous
                    )
                    .fill(palette.cyan)
                    .frame(width: 19, height: 25)
                    .rotationEffect(.degrees(-6))
                    .offset(x: -5, y: -2)

                    Text("En")
                        .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .offset(x: -6, y: -3)

                    Text("文")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(palette.cyan)
                        .offset(x: 8, y: 6)
                }
                .frame(width: 34, height: 34)
            }
        }
        .frame(width: 42, height: 42)
    }
}

private struct TranslationTextDisplay: View {
    let text: String
    let fontSize: CGFloat
    let foregroundColor: Color

    var body: some View {
        SelectableTextDisplay(text: text, fontSize: fontSize, foregroundColor: foregroundColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SelectableTextDisplay: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let foregroundColor: Color

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.drawsBackground = false

        let textView = CopyableTextView()
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.maximumNumberOfLines = 0
        textView.allowsUndo = false
        textView.string = text
        textView.applyBoldLTRStyle(fontSize: fontSize, color: NSColor(foregroundColor))

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            if selectedRange.location <= textView.string.utf16.count {
                textView.setSelectedRange(NSRange(location: selectedRange.location, length: min(selectedRange.length, textView.string.utf16.count - selectedRange.location)))
            }
        }
        textView.textContainer?.containerSize = NSSize(
            width: max(0, scrollView.contentSize.width),
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.applyBoldLTRStyle(fontSize: fontSize, color: NSColor(foregroundColor))
    }
}

private final class CopyableTextView: NSTextView {
    override func copy(_ sender: Any?) {
        let selected = selectedRange()
        guard selected.length > 0,
              let range = Range(selected, in: string)
        else {
            super.copy(sender)
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(string[range]), forType: .string)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            copy(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private struct TranslationActionButton: View {
    var systemName: String?
    var text: String?
    var isActive = false
    var palette: TranslationPalette = TranslationPalette(theme: .system)
    var action: () -> Void
    @State private var isAcknowledging = false

    var body: some View {
        Button {
            action()
            withAnimation(.easeOut(duration: 0.08)) {
                isAcknowledging = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                withAnimation(.easeOut(duration: 0.14)) {
                    isAcknowledging = false
                }
            }
        } label: {
            ZStack {
                if isActive || isAcknowledging {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(buttonFill)
                        .frame(width: 30, height: 30)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(buttonStroke, lineWidth: 1)
                        )
                }

                if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: symbolSize(for: systemName), weight: .medium))
                        .symbolRenderingMode(.monochrome)
                        .frame(width: 20, height: 20)
                } else if let text {
                    Text(text)
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 20, height: 20)
                }
            }
            .foregroundStyle(isActive ? palette.cyan : Color.secondary)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(TranslationActionButtonStyle())
    }

    private func symbolSize(for name: String) -> CGFloat {
        switch name {
        case "doc.on.doc":
            return 16
        case "minus.square":
            return 16
        case "speaker.wave.2":
            return 18
        default:
            return 18
        }
    }

    private var buttonFill: Color {
        if isActive { return palette.cyan.opacity(0.16) }
        if isAcknowledging { return palette.cyan.opacity(0.12) }
        return Color.clear
    }

    private var buttonStroke: Color {
        (isActive || isAcknowledging) ? palette.cyan.opacity(0.35) : Color.clear
    }
}

private struct TranslationActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
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
    @Binding var isEditing: Bool
    let fontSize: CGFloat
    let palette: TranslationPalette
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isEditing: $isEditing, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
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
        textView.textContainer?.maximumNumberOfLines = 0
        let inkColor = NSColor(palette.ink)
        textView.textColor = inkColor
        textView.insertionPointColor = inkColor
        textView.string = text
        textView.applyBoldLTRStyle(fontSize: fontSize, color: inkColor)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text, !context.coordinator.isEditingMarkedText {
            textView.string = text
        }
        let isFirstResponder = textView.window?.firstResponder === textView
        if isFirstResponder {
            context.coordinator.beginEditing(textView)
        }
        let inkColor = NSColor(palette.ink)
        textView.textColor = inkColor
        textView.insertionPointColor = inkColor
        textView.textContainer?.containerSize = NSSize(
            width: max(0, scrollView.contentSize.width),
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.applyBoldLTRStyle(fontSize: fontSize, color: inkColor)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var isEditingBinding: Bool
        weak var textView: NSTextView?
        var isEditingMarkedText = false
        var isEditing = false
        let onSubmit: () -> Void

        init(text: Binding<String>, isEditing: Binding<Bool>, onSubmit: @escaping () -> Void) {
            _text = text
            _isEditingBinding = isEditing
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            beginEditing(textView)
            isEditingMarkedText = textView.hasMarkedText()
            guard !isEditingMarkedText else { return }
            if text != textView.string {
                text = textView.string
            }
        }

        func textDidBeginEditing(_ notification: Notification) {
            if let textView = notification.object as? NSTextView {
                beginEditing(textView)
            }
        }

        func textDidEndEditing(_ notification: Notification) {
            isEditingMarkedText = false
            isEditing = false
            isEditingBinding = false
            if let textView = notification.object as? NSTextView {
                textView.insertionPointColor = textView.textColor ?? .labelColor
                if text != textView.string {
                    text = textView.string
                }
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if let textView = notification.object as? NSTextView,
               textView.window?.firstResponder === textView {
                beginEditing(textView)
            }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            beginEditing(textView)
            return true
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            beginEditing(textView)
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                guard !textView.hasMarkedText() else { return false }
                if text != textView.string {
                    text = textView.string
                }
                onSubmit()
                return true
            }

            if commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true
            }

            return false
        }

        func beginEditing(_ textView: NSTextView) {
            isEditing = true
            isEditingBinding = true
            textView.insertionPointColor = textView.textColor ?? .labelColor
        }
    }
}

private struct MiniIslandPetGlyph: View {
    enum Kind {
        case translation
        case clipboard
    }

    let kind: Kind
    let tint: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            switch kind {
            case .translation:
                translationGlyph
            case .clipboard:
                clipboardGlyph
            }
        }
        .frame(width: size, height: size)
    }

    private var translationGlyph: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .stroke(tint.opacity(0.78), lineWidth: max(1.35, size * 0.08))
                .frame(width: size * 0.64, height: size * 0.5)
                .offset(x: size * 0.08, y: size * 0.02)

            Text("文")
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundStyle(tint)
                .offset(x: -size * 0.12, y: -size * 0.11)

            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: size * 0.26, weight: .bold))
                .foregroundStyle(tint.opacity(0.9))
                .offset(x: size * 0.12, y: size * 0.23)
        }
    }

    private var clipboardGlyph: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                .stroke(tint.opacity(0.82), lineWidth: max(1.35, size * 0.08))
                .frame(width: size * 0.6, height: size * 0.68)
                .offset(y: size * 0.12)

            RoundedRectangle(cornerRadius: size * 0.1, style: .continuous)
                .fill(Color.black.opacity(0.95))
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.1, style: .continuous)
                        .stroke(tint.opacity(0.85), lineWidth: max(1.25, size * 0.07))
                }
                .frame(width: size * 0.34, height: size * 0.18)

            VStack(spacing: size * 0.09) {
                Capsule().fill(tint.opacity(0.86))
                Capsule().fill(tint.opacity(0.62))
            }
            .frame(width: size * 0.35, height: size * 0.22)
            .offset(y: size * 0.36)
        }
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

private extension NSTextView {
    func applyBoldLTRStyle(fontSize: CGFloat, color: NSColor) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        paragraphStyle.baseWritingDirection = .leftToRight
        paragraphStyle.lineBreakMode = .byWordWrapping

        self.font = font
        self.textColor = color
        self.baseWritingDirection = .leftToRight
        self.alignment = .left
        self.defaultParagraphStyle = paragraphStyle
        self.typingAttributes = [
            .font: font,
            .paragraphStyle: paragraphStyle,
            .foregroundColor: color
        ]

        let fullRange = NSRange(location: 0, length: string.utf16.count)
        guard fullRange.length > 0 else { return }
        textStorage?.addAttributes([
            .font: font,
            .paragraphStyle: paragraphStyle,
            .foregroundColor: color
        ], range: fullRange)
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
