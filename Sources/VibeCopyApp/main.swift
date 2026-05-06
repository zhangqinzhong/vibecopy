import AppKit

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated {
    AppDelegate()
}

app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
