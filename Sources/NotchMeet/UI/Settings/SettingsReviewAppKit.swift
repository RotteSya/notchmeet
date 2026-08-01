import AppKit

/// 「面试复盘」页（审计 #21）。
///
/// 此前每场面试的问答只活在内存里，进程结束即蒸发——「哪几问没命中我准备的内容、
/// 下次该往稿子里补什么」这个唯一能让人越面越准的信号，用户永远拿不到。
///
/// 这一页的主角不是流水账，而是**未命中清单**：那就是改稿清单。
final class ReviewSection: SectionScroll {
    private let store: SessionStore
    private let onClear: () -> Void

    init(store: SessionStore, onClear: @escaping () -> Void) {
        self.store = store
        self.onClear = onClear
        super.init(frame: .zero)
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        let s = self.s
        let title = SKBuild.pageTitle(s.secReview)
        var rows: [NSView] = [title, SKBuild.divider()]

        guard store.hasHistory else {
            rows.append(SKBuild.padded(SKBuild.help(Settings.keepSessionHistory ? s.reviewEmpty
                                                                                : s.reviewDisabled,
                                                    color: SK.secondary, size: 12),
                                       top: 20, bottom: 20))
            rows.append(SKBuild.divider())
            scroll.setRows(rows)
            scroll.gap(18, after: title)
            return
        }

        for session in store.sessions {
            rows.append(SKBuild.padded(header(session), top: 16, bottom: 6))
            let misses = session.misses
            if misses.isEmpty {
                rows.append(SKBuild.padded(SKBuild.help(s.reviewAllHit, color: SK.accentHi, size: 11.5),
                                           top: 0, bottom: 14))
            } else {
                rows.append(SKBuild.padded(SKBuild.help(s.reviewMissesTitle(misses.count),
                                                        color: SK.warning, size: 11.5),
                                           top: 0, bottom: 4))
                // 未命中的问题原文＝下次要往稿子里补的题目。答案不展示：那是当时现场
                // 编的，留着只会让人误以为「已经准备好了」。
                for m in misses.prefix(8) {
                    rows.append(SKBuild.padded(SKBuild.help("· \(m.question)", color: SK.secondary, size: 12),
                                               top: 0, bottom: 2))
                }
                if misses.count > 8 {
                    rows.append(SKBuild.padded(SKBuild.help(s.reviewMoreMisses(misses.count - 8)),
                                               top: 0, bottom: 0))
                }
                rows.append(SKBuild.spacer(min: 10))
            }
            rows.append(SKBuild.divider())
        }

        let clearBtn = SKButton(s.reviewClear, kind: .destructive) { [weak self] in self?.confirmClear() }
        rows.append(SKBuild.padded(clearBtn, top: 16, bottom: 20))
        scroll.setRows(rows)
        scroll.gap(18, after: title)
    }

    private func header(_ session: InterviewSession) -> NSView {
        let s = self.s
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        let scriptPart = session.scriptName.map { " · \($0)" } ?? ""
        let line = SKText.label("\(f.string(from: session.startedAt))\(scriptPart)",
                                font: SK.font(13, .semibold), color: SK.ink)
        let stat = SKText.label(s.reviewHitRate(hit: session.hitCount, total: session.turns.count),
                                font: SK.font(11.5, .medium), color: SK.tertiary)
        let stack = NSStackView(views: [line, stat])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        return stack
    }

    private func confirmClear() {
        let s = self.s
        let alert = NSAlert()
        alert.messageText = s.reviewClearConfirmTitle
        alert.informativeText = s.reviewClearConfirmBody
        alert.alertStyle = .warning
        alert.addButton(withTitle: s.reviewClear)
        alert.addButton(withTitle: s.cancel)
        let go: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            self?.store.clear()
            self?.onClear()
        }
        if let w = window { alert.beginSheetModalGuarded(for: w, completionHandler: go) }
        else { go(alert.runModalGuarded()) }
    }
}
