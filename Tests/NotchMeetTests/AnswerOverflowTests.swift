import AppKit
import XCTest
@testable import notchmeet

/// 长答案的溢出处理（审计 #28）。
///
/// 旧行为：卡片高度＝文本高度，一路长到屏幕底，再被 `NotchController` 的
/// `min(desired, screen.height - margin)` 夹住——超出的部分被**窗口**静默切掉，
/// 没有省略号、没有渐隐、没有任何「后面还有」的痕迹。用户读到底部断在半句上，
/// 而且不知道自己漏了内容。
///
/// 现在答案区有固定上限，超出部分在视图内部滚动。
@MainActor
final class AnswerOverflowTests: XCTestCase {

    private func view(width: CGFloat = 480, height: CGFloat) -> StreamingAnswerView {
        let v = StreamingAnswerView()
        v.frame = NSRect(x: 0, y: 0, width: width, height: height)
        return v
    }

    private let longAnswer = String(repeating: "はい。私の強みは、状況を整理してすぐに行動へ移せる点です。", count: 12)

    func testShortAnswerIsNotScrollable() {
        let v = view(height: 200)
        v.setText("はい。私の強みは実行力です。")
        XCTAssertFalse(v.isScrollable)
        XCTAssertEqual(v.maxScroll, 0)
    }

    func testLongAnswerBecomesScrollable() {
        let v = view(height: 120)
        v.setText(longAnswer)
        XCTAssertTrue(v.isScrollable, "长答案必须可滚动，否则又回到静默截断")
        XCTAssertGreaterThan(v.maxScroll, 0)
    }

    /// 位移必须夹在 [0, maxScroll]：滚过头会露出空白，用户以为答案没了。
    func testScrollClampsAtBothEnds() {
        let v = view(height: 120)
        v.setText(longAnswer)

        v.scroll(by: -10_000)                       // 往下滚到底
        XCTAssertEqual(v.scrollOffset, v.maxScroll, accuracy: 0.5)

        v.scroll(by: 10_000)                        // 往上滚到顶
        XCTAssertEqual(v.scrollOffset, 0, accuracy: 0.5)
    }

    /// 流式追加（同一轮的 delta）不能把用户正在读的位置拽走。
    func testStreamingAppendKeepsTheReadingPosition() {
        let v = view(height: 120)
        v.setText(longAnswer)
        v.scroll(by: -40)
        let before = v.scrollOffset
        XCTAssertGreaterThan(before, 0)

        v.setText(longAnswer + "この経験を御社でも生かしたいと考えています。")

        XCTAssertEqual(v.scrollOffset, before, accuracy: 0.5,
                       "纯追加时位移必须保持——否则读到一半被拽回顶部")
    }

    /// 整段换新（下一轮答案、回看切换）必须回到顶部：人是从第一行开始念的，
    /// 停在旧位移上会让用户盯着一段空白，以为答案没出来。
    func testNewAnswerResetsToTop() {
        let v = view(height: 120)
        v.setText(longAnswer)
        v.scroll(by: -60)
        XCTAssertGreaterThan(v.scrollOffset, 0)

        v.setText("まったく別の回答です。前の回答とは共通の先頭を持ちません。")

        XCTAssertEqual(v.scrollOffset, 0, accuracy: 0.001)
    }

    /// 不可滚动时滚轮不该产生位移（否则会把文本推出视野）。
    func testScrollIsInertWhenEverythingFits() {
        let v = view(height: 300)
        v.setText("短い回答です。")
        v.scroll(by: -500)
        XCTAssertEqual(v.scrollOffset, 0)
    }

    /// 量高与渲染必须用**同一个**上限。两处各写各的，就会重现
    /// 「面板按 A 高度开、文字按 B 高度排」那类错位——这正是本项要修的病根。
    ///
    /// 两个合法出口：直接引用 `NotchMetrics.maxAnswerHeight`（控制器量高），或调用
    /// 把封顶与夹取一起封好的 `NotchMetrics.answerHeight(...)`（视图布局）。后者更强——
    /// 式子只有一份，连提示行的预留都算在里面。
    func testHeightCapIsSharedBetweenMeasurementAndLayout() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Sources/NotchMeet/UI/Notch/NotchController.swift",
                     "Sources/NotchMeet/UI/Notch/NotchView.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(text.contains("NotchMetrics.maxAnswerHeight")
                          || text.contains("NotchMetrics.answerHeight("),
                          "\(path) 既没引用共享上限常量，也没走 NotchMetrics.answerHeight")
        }
    }

    /// **绘制必须被视口裁剪**。
    ///
    /// CT 的 frame 高度是 layoutHeight（「足够高」），draw 会把全部行都送进上下文；
    /// 答案区一旦封顶，超出的行若不裁掉就会画到视图之外、越过卡片下缘继续渲染。
    /// 这条 bug 是实机截图发现的：布局数学全对、单测全绿，错在绘制没有边界。
    ///
    /// 注：越界本身无法用 `cacheDisplay` 复现（那条路径 AppKit 会自行按子视图 bounds
    /// 裁剪，写出来的测试是空转的——去掉裁剪照样通过）。所以这里守的是开关本身，
    /// 真正的证据是实机截图。
    func testAnswerViewClipsToItsViewport() {
        XCTAssertTrue(view(height: 120).clipsToBounds,
                      "答案区必须裁剪到视口，否则封顶后的文字会画到卡片之外")
    }

    /// 视口内的**文字**像素数。只数亮像素：按 alpha 数会把渐隐带（接近不透明的
    /// 背景色）算进去，指标就废了。
    private func textPixels(_ v: StreamingAnswerView) throws -> Int {
        final class FlippedBox: NSView { override var isFlipped: Bool { true } }
        let box = FlippedBox(frame: v.bounds)
        box.addSubview(v)
        let rep = try XCTUnwrap(box.bitmapImageRepForCachingDisplay(in: box.bounds))
        box.cacheDisplay(in: box.bounds, to: rep)
        var ink = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if c.alphaComponent > 0.5, c.brightnessComponent > 0.55 { ink += 1 }
            }
        }
        return ink
    }

    /// 逐字出生动画跑完再测量。不等的话读数是动画中途的半透明状态，同一份代码
    /// 两次跑能差一个数量级——我就是被这个骗过一次，误判方向修复无效。
    private func settleBirths() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    }

    /// **滚动方向**：往下滚要露出后文，而不是把正文推出视口。
    ///
    /// scrollOffset 夹取范围对，不代表方向对。翻转后那层空间是 y 向上的，shift 越大
    /// 行原点越低——把位移**加**进 shift 会让文字往下跑，滚到底时视口全空，而用户
    /// 以为答案没了。实测：加号下墨迹 7452→5347→1835→0，减号下始终 ~7000。
    func testScrollingDownRevealsLaterTextInsteadOfPushingItAway() throws {
        let v = view(height: 100)
        v.setText(longAnswer)
        settleBirths()
        XCTAssertGreaterThan(v.maxScroll, 0, "前提：内容要超出视口")

        let atTop = try textPixels(v)
        XCTAssertGreaterThan(atTop, 0, "顶部应当有文字")

        v.scroll(by: -v.maxScroll)                 // 滚到底
        XCTAssertEqual(v.scrollOffset, v.maxScroll, accuracy: 0.5)

        let atBottom = try textPixels(v)
        XCTAssertGreaterThan(atBottom, atTop / 2,
                             "滚到底后视口几乎空了（\(atBottom) vs \(atTop)）——方向反了")
    }
}
