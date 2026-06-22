import AppKit

#if DEBUG
// Visual-QA only: override the working directory so a bundled debug build (launched via
// `open`, cwd = /) can still find the repo's knowledge/ files. Never used in release.
if let i = CommandLine.arguments.firstIndex(of: "--qa-cwd"),
   CommandLine.arguments.indices.contains(i + 1) {
    FileManager.default.changeCurrentDirectoryPath(CommandLine.arguments[i + 1])
}
#endif

// Accessory app: no Dock icon, lives at the notch like a menu-bar app.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
