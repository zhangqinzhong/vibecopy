import AppKit
import ScreenCaptureKit

final class SelectionOverlayWindow: NSWindow {
    private let overlayView: SelectionOverlayView

    init(completion: @escaping (NSImage?) -> Void) {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        overlayView = SelectionOverlayView(screen: screen, completion: completion)
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = overlayView
        makeKey()
    }

    override var canBecomeKey: Bool { true }
}

private final class SelectionOverlayView: NSView {
    private let targetScreen: NSScreen
    private let completion: (NSImage?) -> Void
    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?

    init(screen: NSScreen, completion: @escaping (NSImage?) -> Void) {
        self.targetScreen = screen
        self.completion = completion
        super.init(frame: screen.frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        guard let rect = selectionRect else { return }
        NSColor.clear.setFill()
        rect.fill(using: .clear)
        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        guard let rect = selectionRect, rect.width > 6, rect.height > 6 else {
            window?.close()
            completion(nil)
            return
        }

        window?.orderOut(nil)
        let captureRect = rect
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(80))
            let image = await self.capture(captureRect)
            self.window?.close()
            self.completion(image)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            window?.close()
            completion(nil)
        }
    }

    private var selectionRect: NSRect? {
        guard let startPoint, let currentPoint else { return nil }
        return NSRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(startPoint.x - currentPoint.x),
            height: abs(startPoint.y - currentPoint.y)
        )
    }

    private func capture(_ rectInView: NSRect) async -> NSImage? {
        let screenFrame = targetScreen.frame
        let rectInScreen = convert(rectInView, to: nil).offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
        // SCScreenshotManager works in global (Quartz) coordinates
        let captureRect = CGRect(
            x: rectInScreen.minX,
            y: NSScreen.screens[0].frame.maxY - rectInScreen.maxY,
            width: rectInScreen.width,
            height: rectInScreen.height
        )
        return await withCheckedContinuation { continuation in
            SCScreenshotManager.captureImage(in: captureRect) { cgImage, _ in
                if let cgImage {
                    continuation.resume(returning: NSImage(cgImage: cgImage, size: rectInView.size))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
