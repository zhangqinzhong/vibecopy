import AppKit

final class TranslationWindowController: NSWindowController {
    private let sourceView = NSTextView()
    private let translatedView = NSTextView()
    private let copyButton = NSButton(title: "复制译文", target: nil, action: nil)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OCR 翻译"
        window.center()
        super.init(window: window)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showLoading() {
        showWindow(nil)
        sourceView.string = "正在识别..."
        translatedView.string = ""
    }

    func show(result: TranslationResult) {
        sourceView.string = result.sourceText
        translatedView.string = result.translatedText
        window?.makeKeyAndOrderFront(nil)
    }

    func showError(_ message: String) {
        sourceView.string = ""
        translatedView.string = "处理失败：\(message)"
        window?.makeKeyAndOrderFront(nil)
    }

    private func setup() {
        guard let contentView = window?.contentView else { return }

        let sourceScroll = scrollView(containing: sourceView)
        let translatedScroll = scrollView(containing: translatedView)
        let stack = NSStackView(views: [sourceScroll, translatedScroll])
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 10

        copyButton.target = self
        copyButton.action = #selector(copyTranslatedText)
        copyButton.bezelStyle = .rounded

        [sourceView, translatedView].forEach {
            $0.isEditable = false
            $0.font = .systemFont(ofSize: 14)
            $0.textContainerInset = NSSize(width: 10, height: 10)
        }

        stack.translatesAutoresizingMaskIntoConstraints = false
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        contentView.addSubview(copyButton)

        NSLayoutConstraint.activate([
            copyButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            copyButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: copyButton.bottomAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14)
        ])
    }

    private func scrollView(containing textView: NSTextView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        textView.autoresizingMask = [.width]
        return scrollView
    }

    @objc private func copyTranslatedText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translatedView.string, forType: .string)
    }
}
