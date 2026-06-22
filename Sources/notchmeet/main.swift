import AppKit

// Accessory app: no Dock icon, lives at the notch like a menu-bar app.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
