import XCTest
@testable import notchmeet

final class ChinaDetectionTests: XCTestCase {
    func testShanghaiTimeZoneIsChinaEvenWithJapanLocale() {
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        XCTAssertTrue(Settings.isLikelyInChina(timeZone: tz, locale: Locale(identifier: "ja_JP")))
    }

    func testRegionCNIsChinaEvenWithForeignTimeZone() {
        let tz = TimeZone(identifier: "America/New_York")!
        XCTAssertTrue(Settings.isLikelyInChina(timeZone: tz, locale: Locale(identifier: "zh_CN")))
    }

    func testTokyoNonCNIsNotChina() {
        let tz = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertFalse(Settings.isLikelyInChina(timeZone: tz, locale: Locale(identifier: "ja_JP")))
    }
}
