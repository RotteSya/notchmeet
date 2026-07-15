import AppKit
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
    /// 仅在本轮进入过问答（status 到过 thinking）后，才为「问题/意图」两行预留高度。
    /// 纯 hover / ready 态保持紧凑；卡片收起时复位，下一次展开重新判断。
    private var reservesContentRows = false
    private var collapseWork: DispatchWorkItem?
    private var resizeScheduled = false
    private var lastHandledStatus: AnswerModel.Status?
    private var cancellables = Set<AnyCancellable>()

    private let expandedWidth: CGFloat = 520
    private let minimumExpandedHeight: CGFloat = 72

    init() {
        panel = NotchPanel(contentRect: .zero)
        let view = NotchView(
            model: model,
            onHover: { [weak self] in self?.hover($0) },
            onSettings: { [weak self] in self?.showSettings() },
            onToggleRecording: { [weak self] in self?.onToggleRecording?() }
        )
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        panel.setFrame(frame(expanded: false), display: true)

        // Any model change → re-evaluate expand state after @Published has committed its
        // new value. Deferring by one main-loop turn prevents geometry from reading stale
        // status/text and removes one-frame jumps during streaming.
        model.objectWillChange
            .sink { [weak self] in
                DispatchQueue.main.async { self?.onModelChanged() }
            }
            .store(in: &cancellables)

        // 外观设置（回答字号）变化 → 走既有的 model 通道，让视图重绘 + 面板按新字号量高。
        NotificationCenter.default.publisher(for: .nmAppearanceChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.model.objectWillChange.send() }
            .store(in: &cancellables)
    }

    private var visible = true
    func show() { panel.orderFrontRegardless() }

    func toggleVisibility() {
        visible.toggle()
        if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    // MARK: - Geometry (NSScreen coords are bottom-left origin)

    /// Prefer the built-in display that actually HAS the physical notch (non-zero safe-area top), so
    /// the slab is never placed at the top-center of a notchless external monitor.
    private var screen: NSScreen {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first!
    }

    /// Notch cutout width from the auxiliary top areas; falls back to a top-center
    /// slab on notchless Macs / external displays.
    private var notchWidth: CGFloat {
        let s = screen
        if let l = s.auxiliaryTopLeftArea?.width, let r = s.auxiliaryTopRightArea?.width, l > 0, r > 0 {
            return max(150, s.frame.width - l - r)
        }
        return 200
    }

    /// Height of the collapsed slab. The physical notch cutout's bottom aligns with the **menu-bar
    /// bottom**, which on a notched display can be a point taller than the notch-safe inset (e.g.
    /// 33pt chrome vs 32pt `safeAreaInsets.top`). Using the safe inset leaves the lower edge a hair
    /// (2px) above the real cutout — a visible "short bottom". So take the true top-chrome height;
    /// never shorter than the safe inset, and guard the menu-bar-auto-hide case (chrome → ~0).
    private var notchHeight: CGFloat {
        let s = screen
        let safe = s.safeAreaInsets.top
        guard safe > 0 else { return max(28, safe) }             // notchless display → 28 floor
        let menuBar = s.frame.maxY - s.visibleFrame.maxY         // true top chrome (0 if auto-hidden)
        return max(safe, menuBar)
    }

    /// Points-per-pixel of the target display; every panel edge is snapped to this grid so the
    /// software slab fuses with the hardware notch instead of straddling a physical pixel.
    private var backingScale: CGFloat { screen.backingScaleFactor }

    /// The transparent extension on each side (collapsed) that seats the indicator + settings button
    /// in the menu bar beside the cutout.
    private let collapsedSideExtension: CGFloat = 60

    private func frame(expanded: Bool) -> NSRect {
        let m = NotchGeometry.Metrics(screenFrame: screen.frame, scale: backingScale,
                                      notchWidth: notchWidth, notchHeight: notchHeight)
        if expanded {
            // The visible card is `expandedWidth × expandedHeight`; the panel itself is grown
            // by a transparent margin (sides + bottom, never the top) so the card can cast a
            // soft drop shadow without it being clipped at the panel edge.
            return NotchGeometry.expanded(m, cardWidth: expandedWidth, cardHeight: expandedHeight(),
                                          marginH: NotchMetrics.shadowMarginH,
                                          marginBottom: NotchMetrics.shadowMarginBottom)
        }
        // Collapsed: notch-region walls fused with the cutout, extended to BOTH sides so the
        // indicator and settings button sit in the visible menu-bar space beside it.
        return NotchGeometry.collapsed(m, sideExtension: collapsedSideExtension)
    }

    private func expandedHeight() -> CGFloat {
        // 高度只跟随答案文本的行数。header、识别到的问题、意图三块按固定高度常驻
        // （始终预留，即使此刻为空），所以它们出现/消失不再让高度阶跃；答案区随
        // 文字一行一行单调、连续地增长，不再有“突然长一截”。
        let width = expandedWidth - 40
        // Measure the SAME string the view renders, with the SAME typography (NotchType), so the
        // panel height always matches the drawn answer — no last-line clip, no trailing gap.
        let display = NotchPresentation.text(answer: model.answer, message: model.message,
                                             errorDetail: model.errorDetail, strings: .current)
        let answerHeight = NotchType.answerHeight(display, empty: model.answer.isEmpty, width: width)
        // 进入问答后预留「问题(标签+最多2行,38) + 意图(18)」，使答案到达不再阶跃；
        // 纯 hover/ready 态（尚未进入问答）用紧凑 chrome(54)，下半不留空。
        let chrome: CGFloat = reservesContentRows ? (62 + 38 + 18) : 54
        let desired = max(minimumExpandedHeight, chrome + answerHeight)
        // Leave room for the bottom shadow margin so the card never exceeds the display.
        return min(desired, floor(screen.frame.height) - NotchMetrics.shadowMarginBottom)
    }

    /// System Reduce Motion: collapse every transition to an instant cut.
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func setFrame(expanded: Bool, animate: Bool) {
        let f = frame(expanded: expanded)
        if animate && !reduceMotion {
            // A soft, overshoot-free settle (~out-expo) matched in duration to the NotchView
            // morph tween (NotchPalette.morphDuration) driving the shape radii + content, so the
            // frame and its contents arrive as one body — the liquid notch morph.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = NotchPalette.morphDuration   // 与 NotchView 的 morph tween 严格同长
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.90, 0.24, 1.00)
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
        if reduceMotion { panel.setFrame(target, display: true); return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.80, 0.25, 1.00)
            panel.animator().setFrame(target, display: true)
        }
    }

    private func setExpanded(_ on: Bool) {
        if model.expanded != on {
            model.expanded = on
            // 收起即结束本轮：下次展开（hover/ready）回到紧凑，不再预留问题/意图行。
            if !on { reservesContentRows = false }
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
            switch model.status {
            case .thinking, .streaming, .presenting:
                // 答えが出ている間はマウスが外れても引っ込めない。読み上げ中に勝手に消えるのを防ぐ。
                // 次のターンで差し替わるか、録音停止で待機に戻ったときにだけ畳む。
                collapseWork?.cancel()
            case .error:
                scheduleCollapse(after: 12)
            case .listening, .ready:
                scheduleCollapse(after: 0.6)
            }
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
                reservesContentRows = true
                collapseWork?.cancel()
                setExpanded(true)
            case .listening, .ready:
                // 一轮问答结束、回到待机：清掉本轮预留，下次 hover 回到紧凑矮卡(图1)，
                // 不再残留成带大片留白的高卡(图2)。
                reservesContentRows = false
                if !hovering { scheduleCollapse(after: 6) }
            case .error:
                reservesContentRows = true
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
