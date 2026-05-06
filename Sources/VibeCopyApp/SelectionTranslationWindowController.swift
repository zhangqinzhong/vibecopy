import AppKit
import SwiftUI

final class SelectionTranslationWindowController: NSWindowController {
    private static let islandSize = NSSize(width: 600, height: 360)

    private let translationService: TranslationService
    private let islandModel = TranslationIslandModel()
    private weak var hostingView: NSView?
    private var lastSourceText = ""
    private var lastTranslatedText = ""
    private var sourceLanguage = "zh_CN"
    private var targetLanguage = "en_US"
    private var manualTranslationGeneration = 0
    private var isPinned = false
    private var localEventMonitor: Any?
    private var transitionGeneration = 0
    private var scheduledTranslation: DispatchWorkItem?

    var isIslandVisible: Bool {
        window?.isVisible == true
    }

    init(translationService: TranslationService) {
        self.translationService = translationService

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

        super.init(window: window)

        setupNativeView()
        positionAtIsland()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        scheduledTranslation?.cancel()
        stopDismissMonitoring()
    }

    func showLoading(sourceText: String) {
        scheduledTranslation?.cancel()
        lastSourceText = sourceText
        lastTranslatedText = ""
        applyDetectedLanguagePair(for: sourceText)
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
        applyDetectedLanguagePair(for: result.sourceText)
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
        stopDismissMonitoring()
        window.ignoresMouseEvents = true
        islandModel.phase = .closed

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak window] in
            guard let self, let window, self.transitionGeneration == generation else { return }
            window.orderOut(nil)
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
            speakSource: { [weak self] in NSSpeechSynthesizer().startSpeaking(self?.lastSourceText ?? "") },
            speakResult: { [weak self] in
                guard let self else { return }
                NSSpeechSynthesizer().startSpeaking(self.lastTranslatedText.isEmpty ? self.lastSourceText : self.lastTranslatedText)
            },
            swapLanguages: { [weak self] in self?.swapLanguages() },
            togglePin: { [weak self] in self?.togglePin() },
            dismiss: { [weak self] in self?.dismissIsland() }
        )

        let hostingView = NSHostingView(
            rootView: TranslationIslandView(model: islandModel, actions: actions)
        )
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
            self?.translateTypedText(trimmed, sourceLanguage: self?.sourceLanguage, targetLanguage: self?.targetLanguage)
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

        if let sourceLanguage {
            self.sourceLanguage = sourceLanguage
        }
        if let targetLanguage {
            self.targetLanguage = targetLanguage
        }

        manualTranslationGeneration &+= 1
        let generation = manualTranslationGeneration
        lastTranslatedText = ""
        render(
            mode: .loading,
            sourceText: trimmed,
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
                    sourceText: result.sourceText,
                    translatedText: result.translatedText,
                    sourceLanguage: self.sourceLanguage,
                    targetLanguage: self.targetLanguage
                )
            }
        }
    }

    private func swapLanguages() {
        swap(&sourceLanguage, &targetLanguage)
        islandModel.sourceLanguage = sourceLanguage
        islandModel.targetLanguage = targetLanguage
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

    private func presentIsland() {
        guard let window else { return }
        let finalFrame = islandFrame()
        let isFirstOpen = !window.isVisible
        transitionGeneration &+= 1
        let generation = transitionGeneration
        window.setFrame(finalFrame, display: false)
        window.ignoresMouseEvents = false

        if isFirstOpen {
            islandModel.phase = .closed
            window.alphaValue = 1
            window.orderFrontRegardless()
            window.makeKey()
            startDismissMonitoring()

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
            startDismissMonitoring()
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

    private func startDismissMonitoring() {
        guard localEventMonitor == nil else { return }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.type == .keyDown && event.keyCode == 53 {
                self?.dismissIsland()
                return nil
            }
            return event
        }
    }

    private func stopDismissMonitoring() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
    }

    private static func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: isNotched) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private static func isNotched(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0 ||
            screen.auxiliaryTopLeftArea?.isEmpty == false ||
            screen.auxiliaryTopRightArea?.isEmpty == false
    }

    private func applyDetectedLanguagePair(for text: String) {
        if Self.containsChinese(text) {
            sourceLanguage = "zh_CN"
            targetLanguage = "en_US"
        } else {
            sourceLanguage = "en_US"
            targetLanguage = "zh_CN"
        }
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

private final class TranslationIslandModel: ObservableObject {
    @Published var phase: TranslationIslandPhase = .closed
    @Published var mode: TranslationMode = .empty
    @Published var sourceText = ""
    @Published var translatedText = ""
    @Published var sourceLanguage = "zh_CN"
    @Published var targetLanguage = "en_US"
    @Published var isPinned = false
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
    var dismiss: () -> Void
}

private struct TranslationIslandView: View {
    @ObservedObject var model: TranslationIslandModel
    let actions: TranslationIslandActions

    private let openedSize = CGSize(width: 600, height: 360)
    private let closedSize = CGSize(width: 246, height: 28)
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
        usesOpenedSurface ? openedSize : closedSize
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

                TranslationIslandContent(model: model, actions: actions)
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
                    .stroke(Color.white.opacity(usesOpenedSurface ? 0.72 : 0.82), lineWidth: 1)
            }
            .overlay {
                surfaceShape
                    .stroke(Color.black.opacity(usesOpenedSurface ? 0.035 : 0.025), lineWidth: 0.5)
            }
        }
        .frame(width: openedSize.width, height: openedSize.height, alignment: .top)
        .animation(panelAnimation, value: model.phase)
    }

    private var islandSurface: some View {
        ZStack {
            surfaceShape
            .fill(.ultraThinMaterial)
            .shadow(color: Color.black.opacity(usesOpenedSurface ? 0.075 : 0.065), radius: usesOpenedSurface ? 36 : 16, x: 0, y: usesOpenedSurface ? 22 : 9)
            .shadow(color: Color.black.opacity(usesOpenedSurface ? 0.035 : 0.03), radius: usesOpenedSurface ? 9 : 5, x: 0, y: usesOpenedSurface ? 5 : 2)

            surfaceShape
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(usesOpenedSurface ? 0.9 : 0.96),
                        Color(red: 0.97, green: 0.98, blue: 0.99).opacity(usesOpenedSurface ? 0.78 : 0.9),
                        Color.white.opacity(usesOpenedSurface ? 0.68 : 0.82)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            surfaceShape
            .fill(
                RadialGradient(
                    colors: [
                        Color.white.opacity(usesOpenedSurface ? 0.48 : 0.36),
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
    let actions: TranslationIslandActions

    private let ink = Color(red: 0.08, green: 0.09, blue: 0.11)
    private let muted = Color(red: 0.38, green: 0.4, blue: 0.42)
    private let cyan = Color(red: 0.07, green: 0.75, blue: 0.82)

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .frame(height: 30)
                .padding(.top, 10)

            TranslationPane(
                language: languageLabel(for: model.sourceLanguage),
                languageColor: ink,
                text: sourceBinding,
                placeholder: "输入文本",
                isSource: true,
                mode: model.mode,
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
                language: languageLabel(for: model.targetLanguage),
                languageColor: cyan,
                text: .constant(resultText),
                placeholder: "Enter text",
                isSource: false,
                mode: model.mode,
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
            TranslationActionButton(systemName: "gearshape", action: {})
        }
    }

    private var divider: some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.72))
                .frame(height: 1)
                .overlay(Rectangle().fill(Color.black.opacity(0.07)).frame(height: 0.5), alignment: .bottom)

            Button(action: actions.swapLanguages) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(cyan)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.84))
                            .shadow(color: Color.black.opacity(0.12), radius: 9, x: 0, y: 4)
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

    private func languageLabel(for code: String) -> String {
        switch code {
        case "zh_CN":
            return "中文（普通话，简体）"
        case "en_US":
            return "英语（美国）"
        default:
            return code
        }
    }
}

private struct TranslationPane: View {
    let language: String
    let languageColor: Color
    @Binding var text: String
    let placeholder: String
    let isSource: Bool
    let mode: TranslationMode
    let actions: [TranslationActionButton]

    private let ink = Color(red: 0.08, green: 0.09, blue: 0.11)
    private let quiet = Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.22)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: {}) {
                HStack(spacing: 6) {
                    Text(language)
                        .font(.system(size: 19, weight: .bold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(languageColor)
            }
            .buttonStyle(.plain)

            ZStack(alignment: .topLeading) {
                if isSource {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 38, weight: .bold))
                            .foregroundStyle(quiet)
                            .allowsHitTesting(false)
                    }
                    BoundedTextInput(text: $text, fontSize: 38)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .clipped()
                } else {
                    Text(displayText)
                        .font(.system(size: text.isEmpty ? 38 : 34, weight: .bold))
                        .foregroundStyle(text.isEmpty ? Color(red: 0.07, green: 0.75, blue: 0.82).opacity(0.3) : ink.opacity(mode == .loading ? 0.48 : 0.9))
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
            .foregroundStyle(isActive ? Color(red: 0.07, green: 0.75, blue: 0.82) : Color(red: 0.38, green: 0.4, blue: 0.42))
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct BoundedTextInput: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat

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
        textView.textColor = NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1)
        textView.insertionPointColor = NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1)
        textView.string = text

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.font = .systemFont(ofSize: fontSize, weight: .bold)
        textView.textContainer?.containerSize = NSSize(
            width: max(0, scrollView.contentSize.width),
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        weak var textView: NSTextView?

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
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
