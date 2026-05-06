import AppKit
import SwiftUI
import Translation

struct TranslationResult {
    let sourceText: String
    let translatedText: String
}

final class TranslationService: @unchecked Sendable {
    func translate(
        _ text: String,
        sourceLanguage: String? = nil,
        targetLanguage: String? = nil,
        completion: @escaping @Sendable (TranslationResult) -> Void
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(TranslationResult(sourceText: "", translatedText: "未识别到可翻译文本。"))
            return
        }

        guard Self.containsTranslatableText(trimmed) else {
            completion(TranslationResult(sourceText: trimmed, translatedText: trimmed))
            return
        }

        let detectedSource = Self.containsChinese(trimmed) ? "zh-Hans" : "en-US"
        let sourceLang = Locale.Language(identifier: sourceLanguage.map(Self.toLocaleIdentifier) ?? detectedSource)
        let targetLang = Locale.Language(identifier: targetLanguage.map(Self.toLocaleIdentifier) ?? (detectedSource == "zh-Hans" ? "en-US" : "zh-Hans"))

        Task { @MainActor in
            let availability = LanguageAvailability()
            let status = await availability.status(from: sourceLang, to: targetLang)

            if status == .unsupported {
                completion(TranslationResult(sourceText: trimmed, translatedText: "不支持该语言对的翻译。"))
                return
            }

            if status == .supported {
                // Language pack not installed — use SwiftUI .translationTask to trigger system download UI
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    TranslationDownloadPresenter.present(source: sourceLang, target: targetLang) {
                        continuation.resume()
                    }
                }
            }

            do {
                let session = TranslationSession(installedSource: sourceLang, target: targetLang)
                let response = try await session.translate(trimmed)
                completion(TranslationResult(sourceText: trimmed, translatedText: response.targetText))
            } catch {
                completion(TranslationResult(
                    sourceText: trimmed,
                    translatedText: "翻译失败：\(error.localizedDescription)"
                ))
            }
        }
    }

    private static func toLocaleIdentifier(_ code: String) -> String {
        switch code {
        case "zh_CN": return "zh-Hans"
        case "zh_TW": return "zh-Hant"
        case "en_US": return "en-US"
        case "ja_JP": return "ja-JP"
        default: return code.replacingOccurrences(of: "_", with: "-")
        }
    }

    private static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value)) ||
            (0x3400...0x4DBF).contains(Int(scalar.value))
        }
    }

    private static func containsTranslatableText(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            CharacterSet.letters.contains(scalar) ||
                (0x4E00...0x9FFF).contains(Int(scalar.value)) ||
                (0x3400...0x4DBF).contains(Int(scalar.value))
        }
    }
}

// Hosts a hidden SwiftUI view to drive .translationTask download UI
@MainActor
private final class TranslationDownloadPresenter {
    static func present(
        source: Locale.Language,
        target: Locale.Language,
        completion: @escaping @MainActor () -> Void
    ) {
        let config = TranslationSession.Configuration(source: source, target: target)
        var retainedWindow: NSWindow?
        let view = TranslationDownloadView(config: config) {
            retainedWindow?.orderOut(nil)
            retainedWindow?.close()
            retainedWindow = nil
            completion()
        }
        let hosting = NSHostingController(rootView: view)
        hosting.view.frame = NSRect(x: 0, y: 0, width: 1, height: 1)

        let window = NSWindow(contentViewController: hosting)
        window.setFrame(NSRect(x: -10, y: -10, width: 1, height: 1), display: false)
        window.level = .screenSaver
        window.center()
        retainedWindow = window
        window.orderFrontRegardless()
    }
}

private struct TranslationDownloadView: View {
    let config: TranslationSession.Configuration
    let completion: @MainActor () -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(config) { session in
                try? await session.prepareTranslation()
                completion()
            }
    }
}
