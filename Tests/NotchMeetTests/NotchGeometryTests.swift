import XCTest
import CoreGraphics
@testable import notchmeet

/// Pixel-exact placement of the notch slab against the physical cutout. Regression tests for the
/// "程序刘海与硬件刘海错位/穿帮 + 下边缘略短" fix: independent point-rounding used to slide the
/// collapsed slab a physical pixel off the hardware wall, and `safeAreaInsets.top` left the bottom
/// a couple pixels short of the real cutout. Ground-truth numbers below are a real 14″ MacBook Pro
/// (1512×982 @2×, notch 185pt wide, side areas reported 663/664; top chrome 33pt vs safe inset 32).
final class NotchGeometryTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let scale: CGFloat = 2
    private let notchW: CGFloat = 185
    private let notchH: CGFloat = 33            // true top-chrome height the controller now feeds in
    private let sideExt: CGFloat = 60

    private var metrics: NotchGeometry.Metrics {
        .init(screenFrame: screen, scale: scale, notchWidth: notchW, notchHeight: notchH)
    }

    // The single fact the illusion rests on: the collapsed slab's notch-region walls coincide, to
    // the physical pixel, with the hardware notch walls. Collapsed extends `sideExt` on each side,
    // so the notch walls are the panel edges minus that extension. Pre-fix math put them +1px off.
    func testCollapsedNotchWallsFuseWithHardwareNotch() {
        let f = NotchGeometry.collapsed(metrics, sideExtension: sideExt)
        let hwRight = screen.midX + notchW / 2   // 848.5pt — display-centered cutout
        let hwLeft  = screen.midX - notchW / 2   // 663.5pt
        XCTAssertEqual(f.maxX - sideExt, hwRight, accuracy: 0.001, "right wall must fuse (no 穿帮)")
        XCTAssertEqual(f.minX + sideExt, hwLeft,  accuracy: 0.001, "left wall must fuse")
        // …and land on the backing-pixel grid so the walls are crisp, not blurred half-pixels.
        XCTAssertEqual(((f.maxX - sideExt) * scale).rounded(), (f.maxX - sideExt) * scale, accuracy: 0.001)
    }

    // The top of the slab must sit exactly on the display's top edge, or a hairline seam opens at
    // the top of the cutout. Height-then-derive-y guarantees it regardless of fractional heights.
    func testTopEdgePinnedToDisplayTop() {
        let c = NotchGeometry.collapsed(metrics, sideExtension: sideExt)
        XCTAssertEqual(c.maxY, screen.maxY, accuracy: 0.001)
        // The classic round(y)+round(h) ≠ top drift: a fraction-heavy card height must not move it.
        let e = NotchGeometry.expanded(metrics, cardWidth: 520, cardHeight: 87.3,
                                       marginH: 22, marginBottom: 28)
        XCTAssertEqual(e.maxY, screen.maxY, accuracy: 0.001)
    }

    // Collapsed bottom edge reaches the true cutout bottom = display top minus the chrome height,
    // i.e. it is exactly `notchHeight` tall (was 2px short when sourced from `safeAreaInsets.top`).
    func testCollapsedHeightMatchesChrome() {
        let c = NotchGeometry.collapsed(metrics, sideExtension: sideExt)
        XCTAssertEqual(c.height, notchH, accuracy: 0.001)
        XCTAssertEqual(c.minY, screen.maxY - notchH, accuracy: 0.001)
    }

    // Collapsed and expanded must share ONE horizontal center (the notch axis) so the morph rises
    // straight out of the cutout instead of sliding sideways. Collapsed is symmetric here, so its
    // whole panel is centered too.
    func testCollapsedAndExpandedShareNotchCenter() {
        let notchCenter = screen.midX // 756
        let c = NotchGeometry.collapsed(metrics, sideExtension: sideExt)
        let e = NotchGeometry.expanded(metrics, cardWidth: 520, cardHeight: 120,
                                       marginH: 22, marginBottom: 28)
        XCTAssertEqual(c.midX, notchCenter, accuracy: 0.001)
        XCTAssertEqual(e.midX, notchCenter, accuracy: 0.001)
    }

    // The expanded card keeps its exact requested width once the transparent shadow margins are
    // stripped, so the obsidian body is never off by a stray pixel.
    func testExpandedCardWidthPreservedInsideMargins() {
        let e = NotchGeometry.expanded(metrics, cardWidth: 520, cardHeight: 120,
                                       marginH: 22, marginBottom: 28)
        XCTAssertEqual(e.width - 22 * 2, 520, accuracy: 0.001)
    }

    func testPixelAlignSnapsToBackingGrid() {
        XCTAssertEqual(NotchGeometry.pixelAlign(603.5, scale: 2), 603.5, accuracy: 0.0001) // already on grid
        XCTAssertEqual(NotchGeometry.pixelAlign(603.3, scale: 2), 603.5, accuracy: 0.0001) // → nearest 0.5
        XCTAssertEqual(NotchGeometry.pixelAlign(603.1, scale: 2), 603.0, accuracy: 0.0001)
        XCTAssertEqual(NotchGeometry.pixelAlign(100.4, scale: 1), 100.0, accuracy: 0.0001)
    }
}
