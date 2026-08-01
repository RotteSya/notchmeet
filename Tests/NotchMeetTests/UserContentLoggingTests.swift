import XCTest
@testable import notchmeet

/// 用户内容不得无条件进系统日志（审计 H3）。
///
/// NSLog 默认是 public 的：内容进 `/var/db/diagnostics`，保留数天，并随 sysdiagnose
/// 一起被带走——而「删除本地数据」清不掉系统日志。所以面试官的转录原文、用户稿件的
/// 标题，只能在显式开启调试开关时才落日志。
///
/// a0d33c3 修过一次，但只堵了 `commitPending` 那一处；`handleTranscript` 的
/// backchannel 分支被漏掉，而它触发得最频繁（判据之一是长度 < 4，任何 STT 碎片、
/// 误识、断句尾巴都走这条）。所以这组测试不看单点，而是扫源码：任何把转录/标题
/// 变量直接塞进 NSLog 的写法都必须带门。
final class UserContentLoggingTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/NotchMeetTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// 每一条打印用户内容的 NSLog 都必须在同一行带上调试门。
    private func assertGated(_ relativePath: String, gate: String,
                             markers: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        let text = try source(relativePath)
        for (i, sourceLine) in text.components(separatedBy: "\n").enumerated() {
            guard sourceLine.contains("NSLog") else { continue }
            guard markers.contains(where: { sourceLine.contains($0) }) else { continue }
            XCTAssertTrue(sourceLine.contains(gate),
                          """
                          \(relativePath):\(i + 1) 把用户内容写进了无门的 NSLog：
                          \(sourceLine.trimmingCharacters(in: .whitespaces))
                          —— 用户内容只能在 \(gate) 打开时落日志（默认记长度即可）。
                          """,
                          file: file, line: line)
        }
    }

    /// 面试官的转录原文（`q` / `t.text`）。
    func testTranscriptTextNeverReachesTheLogUngated() throws {
        try assertGated("Sources/NotchMeet/Brain/TurnManager.swift",
                        gate: "sttDebug",
                        markers: ["%@\", q)", "%@\", t.text)", "%@\", pendingQ)"])
    }

    /// 用户稿件的标题原文（公司名、个人题目都在里面）。
    func testScriptHeadingNeverReachesTheLogUngated() throws {
        try assertGated("Sources/NotchMeet/Prep/ScriptParser.swift",
                        gate: "parseDebug",
                        markers: ["%@\", heading)"])
    }

    /// 门本身要真的存在且默认关闭——测试进程没设这两个环境变量。
    func testGatesAreOffByDefault() {
        XCTAssertFalse(ScriptParser.parseDebug, "FI_PARSE_DEBUG 默认必须是关的")
        XCTAssertNil(ProcessInfo.processInfo.environment["FI_STT_DEBUG"],
                     "本测试假设 FI_STT_DEBUG 未设置")
    }

    /// 关着门的时候，落日志的仍应是可诊断的长度信息——不能因为堵了泄漏就变成
    /// 「什么都不记」，那会把「有没有收到问题」这个排障信号一起丢掉。
    func testGatedSitesStillLogLengthForDiagnosis() throws {
        let turn = try source("Sources/NotchMeet/Brain/TurnManager.swift")
        XCTAssertTrue(turn.contains("Q received (%d chars)"), "commitPending 应保留长度日志")
        XCTAssertTrue(turn.contains("ignore backchannel (%d chars)"), "backchannel 分支应保留长度日志")

        let parser = try source("Sources/NotchMeet/Prep/ScriptParser.swift")
        XCTAssertTrue(parser.contains("dropped (%d chars)"), "丢弃标题应保留长度日志")
    }
}
