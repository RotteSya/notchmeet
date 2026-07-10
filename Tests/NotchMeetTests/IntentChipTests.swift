import AppKit
import XCTest
@testable import notchmeet

/// 意图 chip 是「一眼核对答的是不是这题」的安全网 —— demo 实测「自己紹介」被裁成
/// 「自己紹」。NSTextField.intrinsicContentSize 少报 cell 内边距（intrinsic 43.0 vs
/// cellSize 46.6），chip 按 intrinsic+2 给宽度 → 末字被截。宽度必须以 cellSize 为准。
final class IntentChipTests: XCTestCase {
    @MainActor
    func testChipGivesLabelItsFullCellWidth() {
        let chip = IntentChipView()
        chip.text = "自己紹介"

        let probe = NSTextField(labelWithString: "")
        probe.attributedStringValue = NSAttributedString(string: "自己紹介", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .kern: 0.2,
        ])
        let needed = probe.cell!.cellSize.width

        chip.frame = NSRect(origin: .zero, size: chip.intrinsicContentSize)
        chip.layoutSubtreeIfNeeded()
        let labelWidth = chip.subviews.compactMap { $0 as? NSTextField }.first?.frame.width ?? 0
        XCTAssertGreaterThanOrEqual(labelWidth, needed - 0.01,
                                    "label got \(labelWidth), needs \(needed) — 末字会被裁掉")
    }
}
