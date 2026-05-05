import AppKit

final class StatusBarController {
    private let item: NSStatusItem

    init(captureAction: @escaping () -> Void, selectionAction: @escaping () -> Void, previewAction: @escaping () -> Void, clipboardAction: @escaping () -> Void, quitAction: @escaping () -> Void) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "VC"
        item.button?.toolTip = "VibeCopy"

        let menu = NSMenu()
        menu.addItem(Self.item("划词翻译", key: "", action: selectionAction))
        menu.addItem(Self.item("打开翻译窗口", key: "", action: previewAction))
        menu.addItem(Self.item("截图 OCR 翻译", key: "", action: captureAction))
        menu.addItem(Self.item("剪贴板历史", key: "", action: clipboardAction))
        menu.addItem(.separator())
        menu.addItem(Self.item("退出", key: "q", action: quitAction))
        item.menu = menu
    }

    private static func item(_ title: String, key: String, action: @escaping () -> Void) -> NSMenuItem {
        let box = MenuActionBox(action)
        let item = NSMenuItem(title: title, action: #selector(MenuActionBox.invoke), keyEquivalent: key)
        item.target = box
        item.representedObject = box
        return item
    }
}

private final class MenuActionBox: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func invoke() {
        action()
    }
}
