import AppKit
import SwiftUI

/// First-launch onboarding. Seven steps — welcome → how-it-works → import script →
/// system-audio permission → gift/activation → live demo → done. Hosted in an NSWindow.
/// The app stays an `.accessory` the whole time: onboarding can be reopened MID-INTERVIEW
/// (设置 → 关于 → 重新运行引导), and flipping to `.regular` would surface a Dock icon +
/// ⌘Tab entry in the shared frame. `activate(ignoringOtherApps:)` is enough for an
/// accessory app's window to take key focus. The backdrop is a live Metal aurora
/// (`AuroraBackground`); the demo drives the REAL notch and permission hits real TCC.
///
/// The step UI and localized copy live alongside this file: `Onboarding/OnboardingView.swift`
/// and `Onboarding/OBStrings.swift`.
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    /// Provide the user's already-saved script (markdown) to preload the editor + demo.
    var loadScript: (() -> String)?
    /// Parse + persist the script, returning how many entries were recognized.
    var onSaveScript: ((String) -> Int)?
    /// Trigger the real macOS audio-capture permission prompt; reports whether it was granted.
    var onRequestPermission: ((@escaping (Bool) -> Void) -> Void)?
    /// Whether an API key (Keychain or env) is already present — seeds the key step's ✓ state.
    var keyPresent: ((String) -> Bool)?
    /// Persist (or clear, when empty) an API key to the Keychain. Going live is deferred to
    /// `onFinish` so no audio tap starts mid-onboarding.
    var onSaveKey: ((_ name: String, _ value: String) -> Void)?
    /// Play the demo on the real notch: stream `answer` under the `intent` tag, and speak
    /// the interviewer's question aloud (`spokenJa`, always Japanese).
    var onPlayDemo: ((_ answer: String, _ intent: String, _ spokenJa: String) -> Void)?
    /// Whether a live interview recording is running right now — the demo then goes visual
    /// only (no TTS through the speakers) and the step shows a 🔇 note.
    var isLiveCapture: (() -> Bool)?
    /// Onboarding finished (or window closed): (permissionGranted, recognizedCount).
    var onFinish: ((Bool, Int) -> Void)?


    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = OnboardingView(
            initialScript: loadScript?() ?? "",
            saveScript: { [weak self] in self?.onSaveScript?($0) ?? 0 },
            requestPermission: { [weak self] cb in self?.onRequestPermission?(cb) },
            keyPresent: { [weak self] name in self?.keyPresent?(name) ?? false },
            saveKey: { [weak self] name, value in self?.onSaveKey?(name, value) },
            playDemo: { [weak self] answer, intent, spokenJa in self?.onPlayDemo?(answer, intent, spokenJa) },
            isLiveCapture: { [weak self] in self?.isLiveCapture?() ?? false },
            finish: { [weak self] granted, count in
                // Bind `self` strongly for the whole closure: `onFinish` drops AppController's
                // only strong ref to this controller (`onboarding = nil`), which would otherwise
                // deallocate us mid-closure and silently skip `window.close()` — the "button
                // does nothing" bug. The strong binding keeps us alive through the close (and
                // its `windowWillClose`, which restores the activation policy).
                guard let self else { return }
                self.onFinish?(granted, count)
                self.window?.close()
            }
        )
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 588, height: 708),
                         styleMask: [.titled, .fullSizeContentView, .closable],
                         backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.backgroundColor = NSColor(red: 0.024, green: 0.027, blue: 0.043, alpha: 1) // #06070b
        w.appearance = NSAppearance(named: .darkAqua)
        // 排除出屏幕采集（PLAN §3 S4）。引导不只在首启出现——「设置 → 关于 → 重新运行引导」
        // 可以在面试中途重开，而它的导入步骤里就是原稿全文。DEBUG + `--visual-qa` 下降级为
        // .readOnly，本地截图 QA 仍可用。
        ScreenShareGuard.exclude(w)
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []          // SwiftUI content must NOT drive the window size
        hosting.layer?.backgroundColor = .clear
        w.contentView = hosting
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        self.window = w

        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
