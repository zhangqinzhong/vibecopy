import AppKit
import ApplicationServices
import Carbon

@MainActor
final class SelectionTranslator {
    private let translationService: TranslationService
    private let settings: AppSettingsModel
    private let showSettings: () -> Void
    private let reader = SelectedTextReader()
    private var windowController: SelectionTranslationWindowController?
    private var translationGeneration = 0

    init(translationService: TranslationService, settings: AppSettingsModel, showSettings: @escaping () -> Void) {
        self.translationService = translationService
        self.settings = settings
        self.showSettings = showSettings
    }

    func translateCurrentSelection() {
        translationGeneration += 1
        let generation = translationGeneration

        reader.readSelectedText { [weak self] text in
            guard let self else { return }
            guard generation == self.translationGeneration else { return }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                self.showFailure()
                return
            }

            let direction = Self.automaticDirection(for: trimmed)
            self.showLoading(sourceText: trimmed, sourceLanguage: direction.source, targetLanguage: direction.target)
            self.translationService.translate(
                trimmed,
                sourceLanguage: direction.source,
                targetLanguage: direction.target
            ) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, generation == self.translationGeneration else { return }
                    self.windowController?.show(result: result)
                }
            }
        }
    }

    private func showLoading(sourceText: String, sourceLanguage: String, targetLanguage: String) {
        NSApp.activate(ignoringOtherApps: true)
        let controller = makeOrReuseWindowController()
        controller.showLoading(
            sourceText: sourceText,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
    }

    private func showFailure() {
        NSApp.activate(ignoringOtherApps: true)
        let controller = makeOrReuseWindowController()
        controller.showNoSelection()
    }

    private func makeOrReuseWindowController() -> SelectionTranslationWindowController {
        if let windowController {
            return windowController
        }

        let controller = SelectionTranslationWindowController(
            translationService: translationService,
            settings: settings,
            showSettings: showSettings
        )
        windowController = controller
        return controller
    }

    private static func automaticDirection(for text: String) -> (source: String, target: String) {
        containsChinese(text) ? ("zh-Hans", "en-US") : ("en-US", "zh-Hans")
    }

    private static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value)) ||
                (0x3400...0x4DBF).contains(Int(scalar.value))
        }
    }
}

private final class SelectedTextReader {
    private let copyTimeout: TimeInterval = 0.8
    private let pollInterval: TimeInterval = 0.05

    func readSelectedText(completion: @escaping (String) -> Void) {
        if let selectedText = readAccessibilitySelectedText() {
            NSLog("VibeCopy selected text read from accessibility: \(selectedText.count)")
            completion(selectedText)
            return
        }

        let pasteboard = NSPasteboard.general
        let oldChangeCount = pasteboard.changeCount
        let oldItems = pasteboard.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    values[type] = data
                }
            }
            return values
        } ?? []

        sendCopy()

        pollPasteboard(
            oldChangeCount: oldChangeCount,
            oldItems: oldItems,
            deadline: Date().addingTimeInterval(copyTimeout),
            completion: completion
        )
    }

    private func pollPasteboard(
        oldChangeCount: Int,
        oldItems: [[NSPasteboard.PasteboardType: Data]],
        deadline: Date,
        completion: @escaping (String) -> Void
    ) {
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount != oldChangeCount {
            let text = pasteboard.string(forType: .string) ?? ""
            NSLog("VibeCopy selected text read from pasteboard: \(text.count)")
            restorePasteboard(oldItems)
            completion(text)
            return
        }

        guard Date() < deadline else {
            NSLog("VibeCopy selected text read timed out")
            restorePasteboard(oldItems)
            completion("")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
            self.pollPasteboard(
                oldChangeCount: oldChangeCount,
                oldItems: oldItems,
                deadline: deadline,
                completion: completion
            )
        }
    }

    private func sendCopy() {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        else { return }

        keyDown.flags = CGEventFlags.maskCommand
        keyUp.flags = CGEventFlags.maskCommand
        keyDown.post(tap: CGEventTapLocation.cghidEventTap)
        keyUp.post(tap: CGEventTapLocation.cghidEventTap)
    }

    private func readAccessibilitySelectedText() -> String? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementValue: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )
        guard focusedStatus == .success, let focusedElementValue else {
            return nil
        }

        let focusedElement = focusedElementValue as! AXUIElement
        var selectedTextValue: CFTypeRef?
        let selectedStatus = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedTextValue
        )
        guard selectedStatus == .success,
              let selectedText = selectedTextValue as? String,
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        return selectedText
    }

    private func restorePasteboard(_ items: [[NSPasteboard.PasteboardType: Data]]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        for values in items {
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            pasteboard.writeObjects([item])
        }
    }
}
