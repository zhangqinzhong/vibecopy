import AppKit
import Carbon

final class SelectionTranslator {
    private let translationService: TranslationService
    private let reader = SelectedTextReader()
    private var windowController: SelectionTranslationWindowController?

    init(translationService: TranslationService) {
        self.translationService = translationService
    }

    func translateCurrentSelection() {
        reader.readSelectedText { [weak self] text in
            guard let self else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                self.showFailure()
                return
            }

            self.showLoading(sourceText: trimmed)
            self.translationService.translate(trimmed) { [weak self] result in
                DispatchQueue.main.async {
                    self?.windowController?.show(result: result)
                }
            }
        }
    }

    private func showLoading(sourceText: String) {
        NSApp.activate(ignoringOtherApps: true)
        windowController = SelectionTranslationWindowController(translationService: translationService)
        windowController?.showLoading(sourceText: sourceText)
    }

    private func showFailure() {
        NSApp.activate(ignoringOtherApps: true)
        windowController = SelectionTranslationWindowController(translationService: translationService)
        windowController?.showNoSelection()
    }
}

private final class SelectedTextReader {
    func readSelectedText(completion: @escaping (String) -> Void) {
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            let text = pasteboard.changeCount == oldChangeCount ? "" : pasteboard.string(forType: .string) ?? ""
            self.restorePasteboard(oldItems)
            completion(text)
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
