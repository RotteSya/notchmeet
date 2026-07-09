import AppKit

/// Owns the settings window. The content is now a pure-AppKit `SettingsRoot` (no SwiftUI
/// hosting), so every plane, control, and transition is hand-drawn to the product's obsidian
/// design language. The window is kept alive across closes so navigation + scroll state
/// persist and the Metal backdrop isn't recompiled each open; the GPU is paused while hidden.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var root: SettingsRoot?
    private let previousPolicy: NSApplication.ActivationPolicy
    private let store: ScriptStore

    var onKeysChanged: (() -> Void)?
    var onBuildBank: (() -> Void)?
    var onDeleteData: (() -> Void)?
    var onRerunOnboarding: (() -> Void)?

    init(store: ScriptStore) {
        self.store = store
        self.previousPolicy = NSApp.activationPolicy()
        super.init()
    }

    func show(section: SettingsSection? = nil) {
        if let window, let root {
            if let section { root.show(section, animated: true) }
            root.setRunning(true)
            present(window)
            return
        }

        let root = SettingsRoot(
            store: store,
            initial: section ?? .general,
            onKeysChanged: { [weak self] in self?.onKeysChanged?() },
            onBuildBank: { [weak self] in self?.onBuildBank?() },
            onDeleteData: { [weak self] in self?.onDeleteData?() },
            onRerunOnboarding: { [weak self] in self?.onRerunOnboarding?() }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 588),
            styleMask: [.titled, .fullSizeContentView, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.backgroundColor = SK.bg
        window.appearance = NSAppearance(named: .darkAqua)
        window.animationBehavior = .documentWindow
        window.contentMinSize = NSSize(width: 760, height: 540)
        window.isReleasedWhenClosed = false
        // The settings window is excluded from screen capture (the live answer must never leak
        // into a shared frame). A DEBUG-only escape hatch lets local visual QA screenshot it.
        #if DEBUG
        window.sharingType = Self.visualQA ? .readOnly : .none
        #else
        window.sharingType = .none
        #endif
        window.delegate = self
        window.contentView = root
        window.center()

        self.window = window
        self.root = root
        present(window)
    }

    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        #if DEBUG
        if Self.visualQA {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                try? "\(window.windowNumber)".write(toFile: "/tmp/nm-settings-window.txt", atomically: true, encoding: .utf8)
                NSLog("FI_SETTINGS_WINDOW=%ld", window.windowNumber)
            }
        }
        #endif
    }

    /// Local visual-QA toggle (env or launch arg), DEBUG-only at the call sites.
    static var visualQA: Bool {
        ProcessInfo.processInfo.environment["FI_VISUAL_QA"] == "1"
            || ProcessInfo.processInfo.arguments.contains("--visual-qa")
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(previousPolicy)
        root?.setRunning(false)
    }
}
