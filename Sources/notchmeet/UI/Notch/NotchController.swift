import AppKit
import SwiftUI
import Combine

/// Hosts the notch panel and drives expand/collapse from the AnswerModel.
/// New turn arrives → auto-expand + stream; turn settles → auto-collapse.
/// (Geometry approach ported from NotchTutor; pipeline driven by the model, not a hotkey.)
final class NotchController {
    let model = AnswerModel()
    var onSettings: ((NSPoint) -> Void)?
    var onToggleRecording: (() -> Void)?

    /// Whether the live notch panel is excluded from screen capture/sharing (PLAN §3 S4).
    /// Read back from the panel itself so the self-check reflects reality, not intent.
    var screenShareGuarded: Bool { panel.sharingType == .none }

    private let panel: NotchPanel
    private var hovering = false
    private var settingsMenuOpen = false
    private var collapseWork: DispatchWorkItem?
    private var resizeScheduled = false
    private var lastHandledStatus: AnswerModel.Status?
    private var cancellables = Set<AnyCancellable>()

    private let expandedWidth: CGFloat = 520
    private let minimumExpandedHeight: CGFloat = 72
    private let expandedHeightStep: CGFloat = 28

    init() {
        panel = NotchPanel(contentRect: .zero)
        let view = NotchView(
            model: model,
            onHover: { [weak self] in self?.hover($0) },
            onSettings: { [weak self] in self?.showSettings() },
            onToggleRecording: { [weak self] in self?.onToggleRecording?() }
        )
        let host = NSHostingView(rootView: view)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        panel.contentView = host
        panel.setFrame(frame(expanded: false), display: true)

        // Any model change → re-evaluate expand state after @Published has committed its
        // new value. Deferring by one main-loop turn prevents geometry from reading stale
        // status/text and removes one-frame jumps during streaming.
        model.objectWillChange
            .sink { [weak self] in
                DispatchQueue.main.async { self?.onModelChanged() }
            }
            .store(in: &cancellables)
    }

    private var visible = true
    func show() { panel.orderFrontRegardless() }

    func toggleVisibility() {
        visible.toggle()
        if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    // MARK: - Geometry (NSScreen coords are bottom-left origin)

    private var screen: NSScreen { NSScreen.main ?? NSScreen.screens.first! }

    /// Notch cutout width from the auxiliary top areas; falls back to a top-center
    /// slab on notchless Macs / external displays.
    private var notchWidth: CGFloat {
        let s = screen
        if let l = s.auxiliaryTopLeftArea?.width, let r = s.auxiliaryTopRightArea?.width, l > 0, r > 0 {
            return max(150, s.frame.width - l - r)
        }
        return 200
    }

    private var notchHeight: CGFloat { max(28, screen.safeAreaInsets.top) }

    private func frame(expanded: Bool) -> NSRect {
        let s = screen.frame
        if expanded {
            let w = expandedWidth
            let h = expandedHeight()
            return NSRect(x: (s.midX - w / 2).rounded(), y: (s.maxY - h).rounded(),
                          width: w.rounded(), height: h.rounded())
        }
        // Collapsed: extend to both sides of the notch so the indicator and settings
        // button sit in the visible menu-bar space beside the physical cutout.
        let sideExt: CGFloat = 60
        let w = notchWidth + sideExt * 2
        let h = notchHeight
        let x = s.midX - notchWidth / 2 - sideExt
        return NSRect(x: x.rounded(), y: (s.maxY - h).rounded(), width: w.rounded(), height: h.rounded())
    }

    private func expandedHeight() -> CGFloat {
        let width = expandedWidth - 40
        let text = model.answer.isEmpty ? AppStrings.current.runtimeMessage(model.message) : model.answer
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = model.answer.isEmpty ? 2 : 3
        let font = NSFont.systemFont(ofSize: model.answer.isEmpty ? 13 : 15)
        let attr = NSAttributedString(string: text, attributes: [
            .font: font,
            .paragraphStyle: paragraph,
        ])
        let rect = attr.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let intentHeight: CGFloat = model.intentLabel.isEmpty ? 0 : 18
        // Recognized-question row: label + up to 2 wrapped lines (12pt) + the VStack gap.
        let questionHeight: CGFloat = model.question.isEmpty ? 0 : 38
        let chromeHeight: CGFloat = model.answer.isEmpty ? 54 : 62
        let desired = max(minimumExpandedHeight, ceil(rect.height) + chromeHeight + intentHeight + questionHeight)
        // Quantize by roughly one line so streaming remains calm, without an arbitrary
        // card-height cap: normal answers grow until every line is visible.
        let natural = ceil(desired / expandedHeightStep) * expandedHeightStep
        return min(natural, floor(screen.frame.height))
    }

    private func setFrame(expanded: Bool, animate: Bool) {
        let f = frame(expanded: expanded)
        if animate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 0.82, 0.22, 1.00)
                panel.animator().setFrame(f, display: true)
            }
        } else {
            panel.setFrame(f, display: true)
        }
    }

    private func resizeToFit() {
        guard model.expanded else { return }
        let target = frame(expanded: true)
        guard abs(panel.frame.height - target.height) >= 2 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.80, 0.25, 1.00)
            panel.animator().setFrame(target, display: true)
        }
    }

    private func setExpanded(_ on: Bool) {
        if model.expanded != on {
            model.expanded = on
            setFrame(expanded: on, animate: true)
        }
    }

    // MARK: - Hover + status-driven expand/collapse

    private func hover(_ inside: Bool) {
        hovering = inside
        if inside {
            collapseWork?.cancel()
            setExpanded(true)
        } else if !settingsMenuOpen {
            scheduleCollapse(after: 0.6)
        }
    }

    private func showSettings() {
        collapseWork?.cancel()
        setExpanded(true)

        // NSMenu accepts screen coordinates when no positioning view is supplied.
        // Anchor it under the rightmost header button so it opens downward from the notch.
        let point = NSPoint(x: panel.frame.maxX - 18, y: panel.frame.maxY - notchHeight)
        onSettings?(point)
    }

    func setSettingsMenuOpen(_ open: Bool) {
        settingsMenuOpen = open
        if open {
            collapseWork?.cancel()
            setExpanded(true)
        } else if !hovering {
            scheduleCollapse(after: 0.6)
        }
    }

    private func onModelChanged() {
        if model.status != lastHandledStatus {
            lastHandledStatus = model.status
            switch model.status {
            case .thinking, .streaming, .presenting:
                collapseWork?.cancel()
                setExpanded(true)
            case .listening, .ready:
                if !hovering { scheduleCollapse(after: 6) }
            case .error:
                collapseWork?.cancel()
                setExpanded(true)
                if !hovering { scheduleCollapse(after: 12) }
            }
        }
        scheduleResize()
    }

    /// Streaming can publish many small text deltas per second. Coalesce geometry work to
    /// the display cadence so SwiftUI can render the text without repeatedly measuring and
    /// animating the NSPanel for every token.
    private func scheduleResize() {
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            self.resizeToFit()
        }
    }

    private func scheduleCollapse(after delay: TimeInterval) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.hovering && !self.settingsMenuOpen { self.setExpanded(false) }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
