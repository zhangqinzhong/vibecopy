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
    private lazy var historyWindowController = ClipboardHistoryWindowController(monitor: clipboardMonitor, settings: settingsModel)
    private var settingsWindowController: SettingsWindowController!
    private lazy var hotKeyManager = GlobalHotKeyManager { [weak self] in
        self?.translateSelection()
    }
    private var previewWindowController: SelectionTranslationWindowController?
    private var statusController: StatusBarController?
    private var hotKeySettingsCancellable: AnyCancellable?
    private var hotKeyConfigurationCancellable: AnyCancellable?

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
        configureHotKeys()
    }

    private func startCapture() {
        NSApp.activate(ignoringOtherApps: true)
        screenshotCoordinator.beginCapture()
    }

    private func showClipboardHistory() {
        NSApp.activate(ignoringOtherApps: true)
        historyWindowController.showWindow(nil)
        historyWindowController.window?.makeKeyAndOrderFront(nil)
    }

    private func translateSelection() {
        selectionTranslator.translateCurrentSelection()
    }

    private func configureHotKeys() {
        updateSelectionHotKey()
        hotKeySettingsCancellable = settingsModel.$selectionHotKeyEnabled
            .sink { [weak self] isEnabled in
                guard let self else { return }
                let status = self.hotKeyManager.setEnabled(isEnabled, configuration: self.settingsModel.selectionHotKey)
                self.settingsModel.updateSelectionHotKeyStatus(status)
            }
        hotKeyConfigurationCancellable = settingsModel.$selectionHotKey
            .sink { [weak self] _ in
                self?.updateSelectionHotKey()
            }
    }

    private func updateSelectionHotKey() {
        let status = hotKeyManager.setEnabled(settingsModel.selectionHotKeyEnabled, configuration: settingsModel.selectionHotKey)
        settingsModel.updateSelectionHotKeyStatus(status)
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
}
