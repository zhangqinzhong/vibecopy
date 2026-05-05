import Foundation

struct TranslationResult {
    let sourceText: String
    let translatedText: String
}

final class TranslationService {
    private let shortcutName: String
    private let timeout: TimeInterval

        self.shortcutName = shortcutName
        self.timeout = timeout
    }

    func translate(
        _ text: String,
        sourceLanguage: String? = nil,
        targetLanguage: String? = nil,
        completion: @escaping (TranslationResult) -> Void
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(TranslationResult(sourceText: "", translatedText: "未识别到可翻译文本。"))
            return
        }

        runShortcut(input: trimmed, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage) { [shortcutName] result in
            switch result {
            case .success(let translatedText):
                completion(TranslationResult(sourceText: trimmed, translatedText: translatedText))
            case .failure(let error):
                completion(TranslationResult(
                    sourceText: trimmed,
                    translatedText: """
                    调用快捷指令失败：\(error.localizedDescription)

                    请确认快捷指令 App 中存在 “\(shortcutName)”，并且它可以接收文本输入、返回翻译文本。
                    """
                ))
            }
        }
    }

    private func runShortcut(
        input: String,
        sourceLanguage: String?,
        targetLanguage: String?,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let shortcutInput: String
        do {
            let detectedSourceLanguage = Self.containsChinese(input) ? "zh_CN" : "en_US"
            let resolvedSourceLanguage = sourceLanguage ?? detectedSourceLanguage
            let resolvedTargetLanguage = targetLanguage ?? (resolvedSourceLanguage == "zh_CN" ? "en_US" : "zh_CN")
            let payload = [
                "text": input,
                "detectFrom": resolvedSourceLanguage,
                "detectTo": resolvedTargetLanguage
            ] as [String: String]
            let data = try JSONSerialization.data(withJSONObject: payload)
            shortcutInput = String(data: data, encoding: .utf8) ?? input
        } catch {
            shortcutInput = input
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            """
            on run argv
                set shortcutName to item 1 of argv
                set inputString to item 2 of argv
                tell application "Shortcuts Events"
                    run the shortcut named shortcutName with input inputString
                end tell
            end run
            """,
            shortcutName,
            shortcutInput
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            completion(.failure(error))
            return
        }

        let deadline = Date().addingTimeInterval(timeout)
        DispatchQueue.global(qos: .userInitiated).async {
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }

            if process.isRunning {
                process.terminate()
                completion(.failure(ShortcutTranslationError.timedOut(self.timeout)))
                return
            }

            let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard process.terminationStatus == 0 else {
                completion(.failure(ShortcutTranslationError.failed(errorOutput)))
                return
            }

            guard !output.isEmpty else {
                completion(.failure(ShortcutTranslationError.emptyOutput))
                return
            }

            completion(.success(output))
        }
    }

    private static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value)) ||
            (0x3400...0x4DBF).contains(Int(scalar.value))
        }
    }
}

private enum ShortcutTranslationError: LocalizedError {
    case timedOut(TimeInterval)
    case failed(String)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .timedOut(let timeout):
            return "快捷指令超过 \(Int(timeout)) 秒未返回。"
        case .failed(let message):
            return message.isEmpty ? "快捷指令执行失败。" : message
        case .emptyOutput:
            return "快捷指令没有返回任何文本。"
        }
    }
}
