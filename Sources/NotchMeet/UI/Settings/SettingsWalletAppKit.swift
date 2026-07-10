import AppKit
import Combine

// 「额度与充值」——商业中枢，也是最该讲究的一页：余额环 + 弹簧计数的大数字、
// 一格粘贴即到账的兑换、一键直达的购买入口。所有动效走 SettingsKit 的
// Spring/DisplayLoop（Reduce Motion 时直接落位），与全产品同一套呼吸。

// MARK: - Section

final class WalletSection: SectionScroll {
    private let onKeysChanged: () -> Void
    private let hero = WalletHeroView()
    private var redeemField: SKField!
    private var feedback: NSTextField!
    private var cancellable: AnyCancellable?

    init(onKeysChanged: @escaping () -> Void) {
        self.onKeysChanged = onKeysChanged
        super.init(frame: .zero)
        let s = self.s

        let title = SKBuild.pageTitle(s.secWallet)

        // 兑换：标题 + 输入行 + 就地反馈。回车或点按都触发。
        redeemField = SKField(placeholder: s.walletRedeemPlaceholder, monospaced: true)
        redeemField.translatesAutoresizingMaskIntoConstraints = false
        redeemField.onSubmit = { [weak self] in self?.redeem() }
        let redeemBtn = SKButton(s.walletRedeemButton, kind: .primary) { [weak self] in self?.redeem() }
        redeemBtn.minWidth = 76
        feedback = SKText.label("", font: SK.font(12, .medium), color: SK.secondary)
        feedback.translatesAutoresizingMaskIntoConstraints = false

        let redeemRow = NSStackView(views: [redeemField, redeemBtn])
        redeemRow.orientation = .horizontal
        redeemRow.alignment = .centerY
        redeemRow.spacing = 8
        redeemRow.translatesAutoresizingMaskIntoConstraints = false
        redeemField.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let redeemBlock = FlippedView()
        let redeemTitle = SKText.label(s.walletRedeemTitle, font: SK.font(14, .semibold), color: SK.ink)
        [redeemTitle, redeemRow, feedback].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            redeemBlock.addSubview($0)
        }
        NSLayoutConstraint.activate([
            redeemTitle.topAnchor.constraint(equalTo: redeemBlock.topAnchor, constant: 20),
            redeemTitle.leadingAnchor.constraint(equalTo: redeemBlock.leadingAnchor),
            redeemRow.topAnchor.constraint(equalTo: redeemTitle.bottomAnchor, constant: 11),
            redeemRow.leadingAnchor.constraint(equalTo: redeemBlock.leadingAnchor),
            redeemRow.trailingAnchor.constraint(equalTo: redeemBlock.trailingAnchor),
            feedback.topAnchor.constraint(equalTo: redeemRow.bottomAnchor, constant: 9),
            feedback.leadingAnchor.constraint(equalTo: redeemBlock.leadingAnchor),
            feedback.trailingAnchor.constraint(equalTo: redeemBlock.trailingAnchor),
            feedback.bottomAnchor.constraint(equalTo: redeemBlock.bottomAnchor, constant: -20),
        ])

        let buyBtn = SKButton(s.walletBuyButton, systemImage: "arrow.up.forward", kind: .secondary) {
            NSWorkspace.shared.open(Provisioning.buyURL)
        }

        scroll.setRows([
            title,
            SKBuild.divider(),
            SKBuild.padded(hero, top: 24, bottom: 24),
            SKBuild.divider(),
            redeemBlock,
            SKBuild.divider(),
            SKBuild.controlRow(s.walletBuyTitle, control: buyBtn, help: s.walletBuyBody),
            SKBuild.divider(),
            SKBuild.help(s.creditNotMetered),
        ])
        scroll.gap(18, after: title)
        scroll.gap(16, after: scroll.stack.arrangedSubviews[scroll.stack.arrangedSubviews.count - 2])

        refreshHero(animated: false)
        cancellable = CreditManager.shared.$balanceSeconds
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshHero(animated: true) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func refreshHero(animated: Bool) {
        let credit = CreditManager.shared
        hero.update(balance: credit.balanceSeconds,
                    granted: credit.grantedSeconds,
                    used: credit.usedSeconds,
                    giftNote: credit.welcomeGrantedThisLaunch ? s.walletGiftNote : nil,
                    strings: s,
                    animated: animated && !SKMotion.reduced)
    }

    private func redeem() {
        let s = self.s
        let raw = redeemField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        switch CreditManager.shared.redeem(raw) {
        case .success(let minutes, let carriesKeys):
            redeemField.stringValue = ""
            showFeedback(s.walletRedeemSuccess(minutes), color: SK.accent)
            if carriesKeys { onKeysChanged() }
        case .alreadyRedeemed:
            showFeedback(s.walletRedeemAlready, color: SK.warning)
        case .expired:
            showFeedback(s.walletRedeemExpired, color: SK.warning)
        case .invalid:
            showFeedback(s.walletRedeemInvalid, color: SK.destructive)
        case .notACode:
            // 兼容 nmk1 设置码（运维发放：只激活服务，不入账）。
            if let keys = SetupCode.decode(raw) {
                for (name, value) in keys {
                    let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !v.isEmpty else { continue }
                    Secrets.set(name, v)
                    Settings.markKeyManaged(name, true)
                }
                redeemField.stringValue = ""
                showFeedback(s.walletRedeemKeysApplied, color: SK.accent)
                onKeysChanged()
            } else {
                showFeedback(s.walletRedeemInvalid, color: SK.destructive)
            }
        }
    }

    /// 就地反馈：淡入 + 轻微上浮，不打断输入焦点。
    private func showFeedback(_ text: String, color: NSColor) {
        feedback.stringValue = text
        feedback.textColor = color
        guard !SKMotion.reduced else { return }
        feedback.alphaValue = 0
        NSAnimationContext.runAnimationGroup { c in
            c.duration = SK.control * 2
            feedback.animator().alphaValue = 1
        }
    }
}

// MARK: - Hero（余额环 + 弹簧数字）

/// 左：环形余量表（额度占累计获得的比例，随余额变色）；右：大数字分钟 + 统计行。
/// 数字与环共用一根弹簧，兑换到账时一起「涨」上去——到账感比任何文案都直接。
final class WalletHeroView: FlippedView {
    private let ring = WalletRingView()
    private let numeral = SKText.label("0", font: SK.mono(34, .semibold), color: SK.ink)
    private let unit = SKText.label("", font: SK.font(13, .medium), color: SK.secondary)
    private let kicker = SKText.label("", font: SK.font(11.5, .semibold), color: SK.tertiary, tracking: 0.8)
    private let stats = SKText.label("", font: SK.font(12), color: SK.secondary)
    private let gift = SKText.label("", font: SK.font(12), color: SK.accent)

    private var loop: DisplayLoop?
    private let spring = Spring(0, stiffness: 120, damping: 16)   // 慢而稳的「到账」涨幅
    private var targetMinutes: CGFloat = 0
    private var unitText = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        [ring, numeral, unit, kicker, stats, gift].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        let baseline = numeral.lastBaselineAnchor
        NSLayoutConstraint.activate([
            ring.leadingAnchor.constraint(equalTo: leadingAnchor),
            ring.topAnchor.constraint(equalTo: topAnchor),
            ring.widthAnchor.constraint(equalToConstant: 116),
            ring.heightAnchor.constraint(equalToConstant: 116),
            ring.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),

            kicker.leadingAnchor.constraint(equalTo: ring.trailingAnchor, constant: 24),
            kicker.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            numeral.leadingAnchor.constraint(equalTo: kicker.leadingAnchor),
            numeral.topAnchor.constraint(equalTo: kicker.bottomAnchor, constant: 4),
            unit.leadingAnchor.constraint(equalTo: numeral.trailingAnchor, constant: 6),
            unit.lastBaselineAnchor.constraint(equalTo: baseline),

            stats.leadingAnchor.constraint(equalTo: kicker.leadingAnchor),
            stats.topAnchor.constraint(equalTo: numeral.bottomAnchor, constant: 8),
            stats.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            gift.leadingAnchor.constraint(equalTo: kicker.leadingAnchor),
            gift.topAnchor.constraint(equalTo: stats.bottomAnchor, constant: 4),
            gift.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            gift.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
        heightAnchor.constraint(greaterThanOrEqualToConstant: 116).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(balance: Int, granted: Int, used: Int, giftNote: String?,
                strings s: AppStrings, animated: Bool) {
        kicker.stringValue = s.creditRemainingLabel
        unitText = s.walletUnitMinutes
        stats.stringValue = "\(s.creditGrantedLabel) \(s.creditMinutes(granted)) · \(s.creditUsedLabel) \(s.creditMinutes(used))"
        gift.stringValue = giftNote ?? ""
        gift.isHidden = giftNote == nil

        targetMinutes = CGFloat(balance) / 60
        let fraction = granted > 0 ? CGFloat(balance) / CGFloat(granted) : 0
        ring.setFraction(fraction, lowSeconds: balance, animated: animated)

        if animated {
            spring.target = targetMinutes
            startLoop()
        } else {
            spring.snap(targetMinutes)
            render()
        }
    }

    private func startLoop() {
        if loop == nil {
            loop = DisplayLoop(host: self)
            loop?.onTick = { [weak self] dt in
                guard let self else { return false }
                let alive = self.spring.step(dt)
                self.render()
                return alive
            }
        }
        loop?.start()
    }

    private func render() {
        numeral.stringValue = "\(max(0, Int(spring.value.rounded())))"
        unit.stringValue = unitText
    }
}

/// 余量环：底轨 + 品牌渐变弧，低于 10 分钟转琥珀、3 分钟转红（与刘海胶囊同一语义）。
final class WalletRingView: FlippedView {
    private let fracSpring = Spring(0, stiffness: 140, damping: 18)
    private var loop: DisplayLoop?
    private var lowSeconds = Int.max

    func setFraction(_ f: CGFloat, lowSeconds: Int, animated: Bool) {
        self.lowSeconds = lowSeconds
        let clamped = max(0, min(1, f))
        if animated {
            fracSpring.target = clamped
            if loop == nil {
                loop = DisplayLoop(host: self)
                loop?.onTick = { [weak self] dt in
                    guard let self else { return false }
                    let alive = self.fracSpring.step(dt)
                    self.needsDisplay = true
                    return alive
                }
            }
            loop?.start()
        } else {
            fracSpring.snap(clamped)
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        let lineW: CGFloat = 9
        let r = (min(b.width, b.height) - lineW) / 2
        let c = CGPoint(x: b.midX, y: b.midY)

        // 底轨
        ctx.setStrokeColor(SK.ink(0.08).cgColor)
        ctx.setLineWidth(lineW)
        ctx.setLineCap(.round)
        ctx.addArc(center: c, radius: r, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ctx.strokePath()

        let f = max(0, min(1, fracSpring.value))
        guard f > 0.001 else { return }

        let tint: NSColor = lowSeconds <= 180 ? NotchPalette.recording
                          : (lowSeconds <= 600 ? SK.warning : SK.accent)
        // 12 点起顺时针（flipped 坐标系里角度取反）。
        let start = -CGFloat.pi / 2
        let end = start + 2 * .pi * f
        ctx.setStrokeColor(tint.cgColor)
        ctx.setLineWidth(lineW)
        ctx.setLineCap(.round)
        ctx.addArc(center: c, radius: r, startAngle: start, endAngle: end, clockwise: false)
        ctx.strokePath()
        // 顶端一点高光，让弧有玻璃感而不是色条。
        ctx.setBlendMode(.plusLighter)
        ctx.setStrokeColor(tint.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(lineW * 0.4)
        ctx.addArc(center: c, radius: r + lineW * 0.18, startAngle: start, endAngle: end, clockwise: false)
        ctx.strokePath()
    }
}
