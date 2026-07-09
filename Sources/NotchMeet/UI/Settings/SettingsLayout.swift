import AppKit

// Layout primitives shared by every section, so the vertical rhythm lives in one place and
// the section code reads as a declarative list of rows — the AppKit equivalent of the old
// SwiftUI VStack, but pixel-exact and capped to a readable measure.

/// A top-left-origin container so manual frames and stacked content read y-down.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Scroll column

/// A vertical scroll column with a readable-width cap (720pt) and the section insets the
/// reference grid uses. Content is a vertical stack; rows are pinned to the column measure.
final class SKScroll: NSView {
    let stack = NSStackView()
    private let scroll = NSScrollView()
    private let doc = FlippedView()

    init(top: CGFloat = 30, bottom: CGFloat = 32, hInset: CGFloat = 36, maxWidth: CGFloat = 580) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        addSubview(scroll)

        doc.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)

        let clip = scroll.contentView
        let grow = stack.widthAnchor.constraint(equalTo: doc.widthAnchor, constant: -2 * hInset)
        grow.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: clip.widthAnchor),

            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: top),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: hInset),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -bottom),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor, constant: -hInset),
            grow,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Replace the column's rows. Each row is pinned to the column measure (full width).
    func setRows(_ rows: [NSView]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for row in rows {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    func gap(_ spacing: CGFloat, after view: NSView) { stack.setCustomSpacing(spacing, after: view) }
}

// MARK: - Builders

enum SKBuild {
    static func pageTitle(_ s: String) -> NSTextField {
        SKText.label(s, font: SK.font(23.5, .semibold), color: SK.ink, tracking: -0.3)
    }

    /// Title + optional help, the standard left column of a setting row.
    static func heading(_ title: String, help: String? = nil, titleSize: CGFloat = 14) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(SKText.label(title, font: SK.font(titleSize, .semibold), color: SK.ink))
        if let help {
            let h = SKText.label(help, font: SK.font(12), color: SK.secondary, lineSpacing: 2.5)
            h.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(h)
        }
        return stack
    }

    static func help(_ s: String, color: NSColor = SK.tertiary, size: CGFloat = 11.5) -> NSTextField {
        SKText.label(s, font: SK.font(size), color: color, lineSpacing: 2.5)
    }

    static func divider() -> SKHairline {
        let h = SKHairline()
        h.translatesAutoresizingMaskIntoConstraints = false
        h.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return h
    }

    /// A flexible horizontal spacer that absorbs slack so trailing controls right-align.
    static func spacer(min: CGFloat = 12) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        v.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        v.widthAnchor.constraint(greaterThanOrEqualToConstant: min).isActive = true
        return v
    }

    /// `leading … <spacer> … trailing`, vertically centred, wrapped with vertical padding.
    static func row(_ leading: NSView, _ trailing: NSView?, vPad: CGFloat = 18,
                    align: NSLayoutConstraint.Attribute = .centerY) -> NSView {
        let h = NSStackView()
        h.orientation = .horizontal
        h.alignment = align == .top ? .top : .centerY
        h.spacing = 16
        h.translatesAutoresizingMaskIntoConstraints = false
        h.addArrangedSubview(leading)
        h.addArrangedSubview(spacer())
        if let trailing { h.addArrangedSubview(trailing) }
        return padded(h, top: vPad, bottom: vPad)
    }

    /// Wrap `view` in a container with the given padding, pinned full-width.
    static func padded(_ view: NSView, top: CGFloat, bottom: CGFloat,
                       leading: CGFloat = 0, trailing: CGFloat = 0) -> NSView {
        let c = FlippedView()
        c.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: c.topAnchor, constant: top),
            view.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -bottom),
            view.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: leading),
            view.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -trailing),
        ])
        return c
    }

    /// A horizontal group of controls (right side of a row), hugging its content.
    static func cluster(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let h = NSStackView(views: views)
        h.orientation = .horizontal
        h.alignment = .centerY
        h.spacing = spacing
        h.setContentHuggingPriority(.required, for: .horizontal)
        return h
    }

    /// `title … control` on one line with optional help wrapping full-width beneath — the
    /// canonical setting row. Uses explicit constraints so the body text actually wraps
    /// (AppKit labels need a bounded width, unlike SwiftUI).
    static func controlRow(_ title: String, control: NSView?, help: String? = nil,
                           vPad: CGFloat = 18, titleSize: CGFloat = 14) -> NSView {
        let c = FlippedView()
        let titleLabel = SKText.label(title, font: SK.font(titleSize, .semibold), color: SK.ink)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        c.addSubview(titleLabel)

        var cons = [
            titleLabel.topAnchor.constraint(equalTo: c.topAnchor, constant: vPad),
            titleLabel.leadingAnchor.constraint(equalTo: c.leadingAnchor),
        ]
        var lastBottom = titleLabel.bottomAnchor

        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            c.addSubview(control)
            cons += [
                control.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
                control.trailingAnchor.constraint(equalTo: c.trailingAnchor),
                control.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16),
            ]
        } else {
            cons.append(titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor))
        }

        if let help {
            let h = SKText.label(help, font: SK.font(12), color: SK.secondary, lineSpacing: 2.5)
            h.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(h)
            cons += [
                h.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
                h.leadingAnchor.constraint(equalTo: c.leadingAnchor),
                h.trailingAnchor.constraint(equalTo: c.trailingAnchor),
            ]
            lastBottom = h.bottomAnchor
        }
        cons.append(lastBottom.constraint(equalTo: c.bottomAnchor, constant: -vPad))
        NSLayoutConstraint.activate(cons)
        return c
    }

    /// A heading (semibold) above a full-width body paragraph — used for the data-flow
    /// disclosure, where there is no control.
    static func textBlock(_ title: String, _ body: String, vPad: CGFloat = 22) -> NSView {
        let c = FlippedView()
        let t = SKText.label(title, font: SK.font(14, .semibold), color: SK.ink)
        let b = SKText.label(body, font: SK.font(12), color: SK.secondary, lineSpacing: 2.5)
        [t, b].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; c.addSubview($0) }
        NSLayoutConstraint.activate([
            t.topAnchor.constraint(equalTo: c.topAnchor, constant: vPad),
            t.leadingAnchor.constraint(equalTo: c.leadingAnchor),
            t.trailingAnchor.constraint(equalTo: c.trailingAnchor),
            b.topAnchor.constraint(equalTo: t.bottomAnchor, constant: 8),
            b.leadingAnchor.constraint(equalTo: c.leadingAnchor),
            b.trailingAnchor.constraint(equalTo: c.trailingAnchor),
            b.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -vPad),
        ])
        return c
    }

    /// Title, then a left-aligned control beneath it, then full-width help — used when the
    /// control is wide (the capture-target popup).
    static func stackedControl(_ title: String, control: NSView, help: String?, vPad: CGFloat = 20) -> NSView {
        let c = FlippedView()
        let t = SKText.label(title, font: SK.font(14, .semibold), color: SK.ink)
        t.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(t); c.addSubview(control)
        var cons = [
            t.topAnchor.constraint(equalTo: c.topAnchor, constant: vPad),
            t.leadingAnchor.constraint(equalTo: c.leadingAnchor),
            t.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor),
            control.topAnchor.constraint(equalTo: t.bottomAnchor, constant: 11),
            control.leadingAnchor.constraint(equalTo: c.leadingAnchor),
        ]
        var lastBottom = control.bottomAnchor
        if let help {
            let h = SKText.label(help, font: SK.font(11.5), color: SK.secondary, lineSpacing: 2.5)
            h.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(h)
            cons += [
                h.topAnchor.constraint(equalTo: control.bottomAnchor, constant: 11),
                h.leadingAnchor.constraint(equalTo: c.leadingAnchor),
                h.trailingAnchor.constraint(equalTo: c.trailingAnchor),
            ]
            lastBottom = h.bottomAnchor
        }
        cons.append(lastBottom.constraint(equalTo: c.bottomAnchor, constant: -vPad))
        NSLayoutConstraint.activate(cons)
        return c
    }
}
