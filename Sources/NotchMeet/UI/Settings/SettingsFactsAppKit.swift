import AppKit

/// 「简历事实」编辑页（审计 #18）。
///
/// `FactSheet` 一直有数据模型、有读取器、有三处消费者（现场生成的 grounding、预生成、
/// 路由上下文），却**没有任何写入口**——于是普通用户的事实上下文恒为空，LLM 又被明令
/// 禁止编造数字，遇到「希望年収は？」「入社可能時期は？」只能给一句没有数字的空话。
/// 这一页就是那个缺掉的写入口。
///
/// 形态刻意与「面试原稿」页一致：一个文本井 + 实时识别计数 + 示例，而不是嵌套表单——
/// 用户已经学过一次这套约定，且解析全程离线确定性（见 FactsTextFormat）。
final class FactsSection: SectionScroll {
    private let store: FactStore
    private let onSaved: () -> Void

    private var well: SKTextWell!
    private var preview: NSTextField!
    private var saveBtn: SKButton!
    private var statusLine: NSTextField!

    init(store: FactStore, onSaved: @escaping () -> Void) {
        self.store = store
        self.onSaved = onSaved
        super.init(frame: .zero)
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        let s = self.s
        let title = SKBuild.pageTitle(s.secFacts)
        let intro = SKBuild.help(s.factsIntro, color: SK.secondary, size: 12)

        preview = SKText.label("", font: SK.font(11, .medium), color: SK.tertiary)
        preview.maximumNumberOfLines = 2
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let sampleBtn = SKButton(s.insertSample, systemImage: "plus", kind: .plain) { [weak self] in
            self?.insertSample()
        }
        let previewRow = NSStackView(views: [preview, SKBuild.spacer(), sampleBtn])
        previewRow.orientation = .horizontal
        previewRow.alignment = .centerY
        previewRow.spacing = 8

        well = SKTextWell(monospaced: false)
        well.string = FactsTextFormat.text(for: store.sheet)
        well.onChange = { [weak self] _ in self?.refreshPreview() }
        well.translatesAutoresizingMaskIntoConstraints = false
        // 收进默认窗口高度：隐私说明（事实会不会离开本机）必须不滚动就看得见。
        well.heightAnchor.constraint(equalToConstant: 228).isActive = true

        saveBtn = SKButton(s.saveWithShortcut, kind: .primary) { [weak self] in self?.commit() }
        statusLine = SKText.label("", font: SK.font(11, .medium), color: SK.tertiary)
        let saveRow = NSStackView(views: [statusLine, SKBuild.spacer(), saveBtn])
        saveRow.orientation = .horizontal
        saveRow.alignment = .centerY
        saveRow.spacing = 12

        scroll.setRows([
            title,
            SKBuild.divider(),
            SKBuild.padded(intro, top: 16, bottom: 10),
            SKBuild.padded(previewRow, top: 0, bottom: 8),
            SKBuild.padded(well, top: 0, bottom: 12),
            SKBuild.padded(saveRow, top: 0, bottom: 14),
            SKBuild.divider(),
            // 事实只在「把简历要点与原稿发送给 AI」开着时才会离开本机——在写入口原地说清楚，
            // 而不是让用户去隐私页猜。
            SKBuild.padded(SKBuild.help(Settings.sendContextToLLM ? s.factsPrivacyOn : s.factsPrivacyOff),
                           top: 14, bottom: 20),
        ])
        scroll.gap(18, after: title)
        refreshPreview()
    }

    private var parsed: FactSheet { FactsTextFormat.parse(well.string) }

    private func refreshPreview() {
        let sheet = parsed
        let n = FactsTextFormat.summary(sheet)
        let empty = FactsTextFormat.isEmptySheetText(sheet)
        preview.attributedStringValue = SKText.attributed(
            empty ? s.factsNothingRecognized
                  : s.factsRecognition(experiences: n.experiences, motivations: n.motivations,
                                       notes: n.notes, hasProfile: n.hasProfile),
            font: SK.font(11, .medium),
            color: empty ? SK.tertiary : SK.accentHi)
        // 允许保存空表（＝清空事实），只是文案不同；不给「看起来能存其实没存」的按钮。
        saveBtn.isEnabledFlag = true
    }

    private func insertSample() {
        let existing = well.string.trimmingCharacters(in: .whitespacesAndNewlines)
        well.string = existing.isEmpty ? FactsTextFormat.sample
                                       : existing + "\n\n" + FactsTextFormat.sample
        refreshPreview()
    }

    private func commit() {
        let sheet = parsed
        let ok = store.save(sheet)
        statusLine.attributedStringValue = SKText.attributed(
            ok ? s.factsSaved : s.factsSaveFailed,
            font: SK.font(11, .medium),
            color: ok ? SK.accentHi : SK.destructive)
        if ok {
            // 写完把规范形回填编辑器：用户看到的就是真正存下去的东西。
            well.string = FactsTextFormat.text(for: sheet)
            refreshPreview()
            onSaved()
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "s" {
            commit()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
