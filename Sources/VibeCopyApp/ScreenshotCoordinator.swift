import AppKit

final class ScreenshotCoordinator {
    private let ocrService = OCRService()
    private let translationService: TranslationService
    private var overlay: SelectionOverlayWindow?
    private var resultWindow: TranslationWindowController?

    init(translationService: TranslationService) {
        self.translationService = translationService
    }

    func beginCapture() {
        overlay = SelectionOverlayWindow { [weak self] image in
            self?.overlay = nil
            guard let self, let image else { return }
            self.handle(image)
        }
        overlay?.makeKeyAndOrderFront(nil)
    }

    private func handle(_ image: NSImage) {
        resultWindow = TranslationWindowController()
        resultWindow?.showLoading()

        ocrService.recognizeText(in: image) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let text):
                    self.translationService.translate(text) { translated in
                        DispatchQueue.main.async {
                            self.resultWindow?.show(result: translated)
                        }
                    }
                case .failure(let error):
                    self.resultWindow?.showError(error.localizedDescription)
                }
            }
        }
    }
}
