import AppKit
import Combine

enum ClipboardEntryKind: String, CaseIterable, Identifiable, Codable {
    case text
    case link
    case image
    case file

    var id: String { rawValue }
}

struct ClipboardEntry: Identifiable, Equatable, Codable {
    let id: UUID
    let kind: ClipboardEntryKind
    let value: String
    let createdAt: Date
    var isPinned: Bool
    let imageData: Data?
    let fileURLs: [URL]

    init(
        id: UUID = UUID(),
        kind: ClipboardEntryKind,
        value: String,
        createdAt: Date = Date(),
        isPinned: Bool = false,
        imageData: Data? = nil,
        fileURLs: [URL] = []
    ) {
        self.id = id
        self.kind = kind
        self.value = value
        self.createdAt = createdAt
        self.isPinned = isPinned
        self.imageData = imageData
        self.fileURLs = fileURLs
    }

    var previewText: String {
        switch kind {
        case .text, .link:
            return value
        case .image:
            return value.isEmpty ? "图片" : value
        case .file:
            return fileURLs.map(\.lastPathComponent).joined(separator: "\n")
        }
    }

    var fingerprint: String {
        switch kind {
        case .image:
            return "image:\(imageData?.hashValue ?? value.hashValue)"
        case .file:
            return "file:\(fileURLs.map(\.path).joined(separator: "|"))"
        case .link:
            return "link:\(value)"
        case .text:
            return "text:\(value)"
        }
    }
}

final class ClipboardMonitor: NSObject, ObservableObject {
    @Published private(set) var entries: [ClipboardEntry]
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount

    var onChange: (() -> Void)?

    override init() {
        entries = Self.loadEntries()
        super.init()
    }

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
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch entry.kind {
        case .image:
            if let image = entry.image {
                pasteboard.writeObjects([image])
            }
        case .file:
            pasteboard.writeObjects(entry.fileURLs as [NSURL])
        case .text, .link:
            pasteboard.setString(entry.value, forType: .string)
        }

        lastChangeCount = pasteboard.changeCount
    }

    func remove(_ entry: ClipboardEntry) {
        entries.removeAll { $0.id == entry.id }
        notifyChange()
    }

    func togglePin(_ entry: ClipboardEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].isPinned.toggle()
        sortPinnedEntries()
        notifyChange()
    }

    func clear() {
        entries.removeAll()
        notifyChange()
    }

    private func tick() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        guard let entry = Self.entry(from: pasteboard) else { return }
        insertOrPromote(entry)
    }

    private func insertOrPromote(_ entry: ClipboardEntry) {
        if let existingIndex = entries.firstIndex(where: { $0.fingerprint == entry.fingerprint }) {
            let pinned = entries[existingIndex].isPinned
            entries.remove(at: existingIndex)
            entries.insert(
                ClipboardEntry(
                    kind: entry.kind,
                    value: entry.value,
                    createdAt: Date(),
                    isPinned: pinned,
                    imageData: entry.imageData,
                    fileURLs: entry.fileURLs
                ),
                at: 0
            )
        } else {
            entries.insert(entry, at: 0)
        }

        sortPinnedEntries()
        if entries.count > 200 {
            entries.removeLast(entries.count - 200)
        }
        notifyChange()
    }

    private func sortPinnedEntries() {
        entries.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private func notifyChange() {
        Self.saveEntriesAsync(entries)
        onChange?()
    }

    private static func entry(from pasteboard: NSPasteboard) -> ClipboardEntry? {
        if let image = NSImage(pasteboard: pasteboard),
           let data = image.tiffRepresentation {
            return ClipboardEntry(kind: .image, value: "图片", imageData: data)
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           !urls.isEmpty {
            return ClipboardEntry(kind: .file, value: urls.map(\.path).joined(separator: "\n"), fileURLs: urls)
        }

        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        return ClipboardEntry(kind: Self.kind(for: text), value: text)
    }

    private static func kind(for text: String) -> ClipboardEntryKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "mailto"].contains(scheme) {
            return .link
        }
        return .text
    }
}

private extension ClipboardMonitor {
    static let saveQueue = DispatchQueue(label: "app.vibecopy.clipboard-history-save", qos: .utility)

    static var historyFileURL: URL? {
        guard let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return supportDirectory
            .appendingPathComponent("VibeCopy", isDirectory: true)
            .appendingPathComponent("clipboard-history.json")
    }

    static func loadEntries() -> [ClipboardEntry] {
        guard let fileURL = historyFileURL,
              let data = try? Data(contentsOf: fileURL)
        else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entries = try? decoder.decode([ClipboardEntry].self, from: data) else {
            return []
        }

        return entries
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
                return lhs.createdAt > rhs.createdAt
            }
            .prefix(200)
            .map { $0 }
    }

    static func saveEntriesAsync(_ entries: [ClipboardEntry]) {
        let snapshot = entries
        saveQueue.async {
            saveEntries(snapshot)
        }
    }

    static func saveEntries(_ entries: [ClipboardEntry]) {
        guard let fileURL = historyFileURL else { return }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Failed to save clipboard history: \(error.localizedDescription)")
        }
    }
}

private extension ClipboardEntry {
    var image: NSImage? {
        guard let imageData else { return nil }
        return NSImage(data: imageData)
    }
}
