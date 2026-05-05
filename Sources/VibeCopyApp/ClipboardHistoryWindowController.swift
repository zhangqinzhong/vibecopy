import AppKit

final class ClipboardHistoryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let monitor: ClipboardMonitor
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    init(monitor: ClipboardMonitor) {
        self.monitor = monitor
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "剪贴板历史"
        window.center()
        super.init(window: window)
        setup()

        monitor.onChange = { [weak self] in
            self?.tableView.reloadData()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        guard let contentView = window?.contentView else { return }

        let clearButton = NSButton(title: "清空", target: self, action: #selector(clear))
        clearButton.bezelStyle = .rounded

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        column.title = "内容"
        column.width = 500
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 58
        tableView.delegate = self
        tableView.dataSource = self
        tableView.doubleAction = #selector(copySelected)
        tableView.target = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true

        clearButton.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(clearButton)
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            clearButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            clearButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: clearButton.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        monitor.entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("clip-cell")
        let label = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = id
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 2
            field.font = .systemFont(ofSize: 13)
            return field
        }()

        label.stringValue = monitor.entries[row].value
        return label
    }

    @objc private func copySelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < monitor.entries.count else { return }
        monitor.copy(monitor.entries[row])
    }

    @objc private func clear() {
        monitor.clear()
    }
}
