import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var settingsModel = AppSettingsModel()
    private lazy var clipboardMonitor = ClipboardMonitor()
    private lazy var translationService = TranslationService()
    private lazy var screenshotCoordinator = ScreenshotCoordinator(translationService: translationService)
    private lazy var selectionTranslator = SelectionTranslator(
        translationService: translationService,
        settings: settingsModel,
        showSettings: { [weak self] in self?.showSettings() },
        showClipboard: { [weak self] in self?.showClipboardHistory() }
    )
    private lazy var historyWindowController = ClipboardHistoryWindowController(
        monitor: clipboardMonitor,
        settings: settingsModel,
        showSettings: { [weak self] in self?.showSettings() },
        pasteEntry: { [weak self] entry in self?.pasteClipboardEntry(entry) }
    )
    private var settingsWindowController: SettingsWindowController!
    private lazy var selectionHotKeyManager = GlobalHotKeyManager(id: 1) { [weak self] in
        self?.translateSelection()
    }
    private lazy var clipboardHotKeyManager = GlobalHotKeyManager(id: 2) { [weak self] in
        self?.showClipboardHistory()
    }
    private var previewWindowController: SelectionTranslationWindowController?
    private var statusController: StatusBarController?
    private var hotKeySettingsCancellable: AnyCancellable?
    private var hotKeyConfigurationCancellable: AnyCancellable?
    private var clipboardHotKeySettingsCancellable: AnyCancellable?
    private var clipboardHotKeyConfigurationCancellable: AnyCancellable?
    private var appBeforeClipboard: NSRunningApplication?
    private var workspaceActivationObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusBarController(
            captureAction: { [weak self] in self?.startCapture() },
            selectionAction: { [weak self] in self?.translateSelection() },
            previewAction: { [weak self] in self?.showTranslationPreview() },
            clipboardAction: { [weak self] in self?.showClipboardHistory() },
            settingsAction: { [weak self] in self?.showSettings() },
            quitAction: { NSApp.terminate(nil) }
        )

        clipboardMonitor.start()
        settingsWindowController = SettingsWindowController(settings: settingsModel)
        observeActiveApplications()
        configureHotKeys()
    }

    private func startCapture() {
        NSApp.activate(ignoringOtherApps: true)
        screenshotCoordinator.beginCapture()
    }

    private func showClipboardHistory() {
        let currentApp = NSRunningApplication.current
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        if frontmostApp?.processIdentifier != currentApp.processIdentifier {
            appBeforeClipboard = frontmostApp
        }

        NSApp.activate(ignoringOtherApps: true)
        historyWindowController.showWindow(nil)
        historyWindowController.window?.makeKeyAndOrderFront(nil)
    }

    private func pasteClipboardEntry(_ entry: ClipboardEntry) {
        clipboardMonitor.copy(entry)
        historyWindowController.window?.orderOut(nil)

        guard let targetApp = appBeforeClipboard else { return }
        guard Self.ensureAccessibilityPermission() else { return }
        targetApp.activate(options: [.activateAllWindows])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            Self.sendCommandV()
        }
    }

    private func translateSelection() {
        selectionTranslator.translateCurrentSelection()
    }

    private func configureHotKeys() {
        updateSelectionHotKey()
        hotKeySettingsCancellable = settingsModel.$selectionHotKeyEnabled
            .sink { [weak self] isEnabled in
                guard let self else { return }
                let status = self.selectionHotKeyManager.setEnabled(isEnabled, configuration: self.settingsModel.selectionHotKey)
                self.settingsModel.updateSelectionHotKeyStatus(status)
            }
        hotKeyConfigurationCancellable = settingsModel.$selectionHotKey
            .sink { [weak self] newConfig in
                self?.updateSelectionHotKey(with: newConfig)
            }

        updateClipboardHotKey()
        clipboardHotKeySettingsCancellable = settingsModel.$clipboardHotKeyEnabled
            .sink { [weak self] isEnabled in
                guard let self else { return }
                let status = self.clipboardHotKeyManager.setEnabled(isEnabled, configuration: self.settingsModel.clipboardHotKey)
                self.settingsModel.updateClipboardHotKeyStatus(status)
            }
        clipboardHotKeyConfigurationCancellable = settingsModel.$clipboardHotKey
            .sink { [weak self] newConfig in
                self?.updateClipboardHotKey(with: newConfig)
            }
    }

    private func updateSelectionHotKey(with config: HotKeyConfiguration? = nil) {
        let cfg = config ?? settingsModel.selectionHotKey
        let status = selectionHotKeyManager.setEnabled(settingsModel.selectionHotKeyEnabled, configuration: cfg)
        settingsModel.updateSelectionHotKeyStatus(status)
    }

    private func updateClipboardHotKey(with config: HotKeyConfiguration? = nil) {
        let cfg = config ?? settingsModel.clipboardHotKey
        let status = clipboardHotKeyManager.setEnabled(settingsModel.clipboardHotKeyEnabled, configuration: cfg)
        settingsModel.updateClipboardHotKeyStatus(status)
    }

    private func showTranslationPreview() {
        NSApp.activate(ignoringOtherApps: true)
        if previewWindowController == nil {
            previewWindowController = SelectionTranslationWindowController(
                translationService: translationService,
                settings: settingsModel,
                showSettings: { [weak self] in self?.showSettings() },
                showClipboard: { [weak self] in self?.showClipboardHistory() }
            )
        }
        previewWindowController?.showNoSelection()
    }

    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController.showCentered()
        settingsModel.refreshSupportedLanguages()
    }

    private func observeActiveApplications() {
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != NSRunningApplication.current.processIdentifier
            else { return }
            Task { @MainActor in
                self.appBeforeClipboard = app
            }
        }
    }

    private static func ensureAccessibilityPermission() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(9)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)

        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
