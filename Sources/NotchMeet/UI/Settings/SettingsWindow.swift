import AppKit

/// Owns the settings window. The content is now a pure-AppKit `SettingsRoot` (no SwiftUI
/// hosting), so every plane, control, and transition is hand-drawn to the product's obsidian
/// design language. The window is kept alive across closes so navigation + scroll state
/// persist and the Metal backdrop isn't recompiled each open; the GPU is paused while hidden.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var root: SettingsRoot?
    private let store: ScriptStore
    private let factStore: FactStore
    private let sessionStore: SessionStore

    var onKeysChanged: (() -> Void)?
    var onBuildBank: (() -> Void)?
    var onDeleteData: (() -> Void)?
    var onRerunOnboarding: (() -> Void)?

    init(store: ScriptStore, factStore: FactStore, sessionStore: SessionStore) {
        self.store = store
        self.factStore = factStore
        self.sessionStore = sessionStore
        super.init()
    }

    func show(section: SettingsSection? = nil) {
        if let window, let root {
            if let section { root.show(section, animated: true) }
            root.refreshVolatileSection()   // 复盘列表可能在窗口关闭期间变了
            root.setRunning(true)
            present(window)
            return
        }

        let root = SettingsRoot(
            store: store,
            factStore: factStore,
            sessionStore: sessionStore,
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
        // 保持 .accessory 直接拿 key：面试中打开设置时，切到 .regular 会让 app 出现在
        // Dock 与 ⌘Tab 里——共享整屏的面试官看得一清二楚。accessory app 经
        // activate(ignoringOtherApps:) 后窗口一样能成为 key window 并接收键盘输入
        // （已实机验证），根本不需要切策略。
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        #if DEBUG
        if Self.visualQA {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                try? "\(window.windowNumber)".write(toFile: "/tmp/nm-settings-window.txt", atomically: true, encoding: .utf8)
                // key=1 证明 accessory 策略下窗口拿到了键盘焦点（E4 验证钩子）。
                NSLog("FI_SETTINGS_WINDOW=%ld key=%d policy=%ld", window.windowNumber,
                      window.isKeyWindow ? 1 : 0, NSApp.activationPolicy().rawValue)
                for w in NSApp.windows {
                    NSLog("FI_WINDOW class=%@ num=%ld visible=%d sharing=%ld frame=%@",
                          String(describing: type(of: w)), w.windowNumber, w.isVisible ? 1 : 0,
                          w.sharingType.rawValue, NSStringFromRect(w.frame))
                }
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
        root?.setRunning(false)
    }
}
