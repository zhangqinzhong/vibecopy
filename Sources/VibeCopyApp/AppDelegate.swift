import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var settingsModel = AppSettingsModel()
    private lazy var clipboardMonitor = ClipboardMonitor()
    private lazy var translationService = TranslationService()
    private lazy var screenshotCoordinator = ScreenshotCoordinator(translationService: translationService)
    private lazy var selectionTranslator = SelectionTranslator(
        translationService: translationService,
        settings: settingsModel,
        showSettings: { [weak self] in self?.showSettings() }
    )
    private lazy var historyWindowController = ClipboardHistoryWindowController(monitor: clipboardMonitor)
    private lazy var settingsWindowController = SettingsWindowController(settings: settingsModel)
    private var previewWindowController: SelectionTranslationWindowController?
    private var statusController: StatusBarController?

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

    private func showTranslationPreview() {
        NSApp.activate(ignoringOtherApps: true)
        if previewWindowController == nil {
            previewWindowController = SelectionTranslationWindowController(
                translationService: translationService,
                settings: settingsModel,
                showSettings: { [weak self] in self?.showSettings() }
            )
        }
        previewWindowController?.showNoSelection()
    }

    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController.showWindow(nil)
        settingsWindowController.window?.makeKeyAndOrderFront(nil)
        settingsModel.refreshSupportedLanguages()
    }
}
