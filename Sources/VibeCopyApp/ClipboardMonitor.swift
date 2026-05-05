import AppKit

struct ClipboardEntry: Identifiable {
    let id = UUID()
    let value: String
    let createdAt: Date
}

final class ClipboardMonitor: NSObject {
    private(set) var entries: [ClipboardEntry] = []
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount

    var onChange: (() -> Void)?

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func copy(_ entry: ClipboardEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.value, forType: .string)
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func clear() {
        entries.removeAll()
        onChange?()
    }

    private func tick() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              entries.first?.value != text
        else { return }

        entries.insert(ClipboardEntry(value: text, createdAt: Date()), at: 0)
        if entries.count > 100 {
            entries.removeLast(entries.count - 100)
        }
        onChange?()
    }
}
