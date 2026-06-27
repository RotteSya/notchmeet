import XCTest
@testable import notchmeet

/// Guards the version comparison behind "check for updates": the common failure is a lexical
/// string compare ("1.0.9" > "1.0.10"), so these pin the numeric semantics + tag normalization.
final class UpdateCheckerTests: XCTestCase {
    func testNumericComparisonBeatsLexical() {
        XCTAssertTrue(UpdateChecker.isNewer("1.0.10", than: "1.0.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.9", than: "1.0.10"))
    }

    func testEqualOrOlderIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("1.0.1", than: "1.0.1"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.0", than: "1.0.1"))
        XCTAssertTrue(UpdateChecker.isNewer("1.1.0", than: "1.0.9"))
    }

    func testDifferingSegmentCounts() {
        XCTAssertTrue(UpdateChecker.isNewer("1.0.1", than: "1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.0.0"))
    }

    func testNormalizationStripsVPrefix() {
        XCTAssertEqual(UpdateChecker.normalized("v1.0.2"), "1.0.2")
        XCTAssertEqual(UpdateChecker.normalized(" V2.0 "), "2.0")
        XCTAssertTrue(UpdateChecker.isNewer(UpdateChecker.normalized("v1.0.2"),
                                            than: UpdateChecker.normalized("1.0.1")))
    }
}
