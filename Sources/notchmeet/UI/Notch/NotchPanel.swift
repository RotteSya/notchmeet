import AppKit

/// Borderless, non-activating panel that sits at the notch and draws over the menu
/// bar. Non-activating + non-key means it never steals focus from the interview app.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar // above the menu bar so the slab hangs from the notch
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Exclude this panel from ALL screen capture — screenshots, screen recording, and
        // Zoom/Meet/Teams screen share, including "share entire screen" (PLAN §3 S4). The
        // live answer points must never enter a frame the interviewer can see. Note: this
        // blocks software capture only, NOT a camera pointed at the physical display.
        #if DEBUG
        // Explicit local-only visual QA escape hatch. Release builds always remain excluded
        // from capture, regardless of environment variables.
        let process = ProcessInfo.processInfo
        let visualQA = process.environment["FI_VISUAL_QA"] == "1"
            || process.arguments.contains("--visual-qa")
        sharingType = visualQA ? .readOnly : .none
        #else
        sharingType = .none
        #endif
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
