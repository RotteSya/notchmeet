import XCTest
@testable import notchmeet

/// 面试复盘（审计 #21）。此前每场面试的问答只活在内存里、进程结束即蒸发——
/// 「哪几问没命中我准备的内容」这个唯一能让人越面越准的信号，用户永远拿不到。
final class SessionReviewTests: XCTestCase {
    private var dir: String!
    private var original: Bool!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "sess-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        original = Settings.keepSessionHistory
        Settings.keepSessionHistory = true
    }

    override func tearDown() {
        Settings.keepSessionHistory = original
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    private func store() -> SessionStore { SessionStore(directory: dir) }

    func testSessionSurvivesRelaunch() {
        let s = store()
        s.begin(scriptName: "一次面接（△△株式会社）")
        s.record(question: "自己紹介をお願いします。", answer: "はい。", source: .script)
        s.record(question: "希望年収は？", answer: "400万円を希望しております。", source: .fact)
        s.record(question: "最近気になるニュースは？", answer: "その場で作った答え。", source: .live)
        XCTAssertTrue(s.end())

        let reloaded = store()
        XCTAssertEqual(reloaded.sessions.count, 1)
        let session = try! XCTUnwrap(reloaded.sessions.first)
        XCTAssertEqual(session.turns.count, 3)
        XCTAssertEqual(session.scriptName, "一次面接（△△株式会社）", "复盘要知道当时用的是哪份稿")
        XCTAssertNotNil(session.endedAt)
    }

    /// 复盘页的主角：未命中清单＝改稿清单。
    func testMissesAreExactlyTheLiveGeneratedTurns() {
        let s = store()
        s.begin(scriptName: nil)
        s.record(question: "Q1", answer: "A1", source: .script)
        s.record(question: "Q2", answer: "A2", source: .bank)
        s.record(question: "Q3", answer: "A3", source: .fact)
        s.record(question: "Q4", answer: "A4", source: .live)
        s.end()

        let session = try! XCTUnwrap(store().sessions.first)
        XCTAssertEqual(session.hitCount, 3, "原稿/答案库/事实都算准备到了")
        XCTAssertEqual(session.misses.map(\.question), ["Q4"], "只有现场生成的才是未命中")
    }

    /// 一问都没有的场次不留记录——点开又关掉不该产出一条空复盘。
    func testEmptySessionLeavesNoRecord() {
        let s = store()
        s.begin(scriptName: nil)
        s.end()
        XCTAssertTrue(store().sessions.isEmpty)
    }

    /// 关掉开关＝一个字都不记（这是「可关」的全部意义）。
    func testNothingIsRecordedWhenTurnedOff() {
        Settings.keepSessionHistory = false
        let s = store()
        s.begin(scriptName: "稿")
        s.record(question: "Q", answer: "A", source: .live)
        s.end()
        XCTAssertTrue(store().sessions.isEmpty)
    }

    func testClearRemovesEverythingFromDisk() {
        let s = store()
        s.begin(scriptName: nil)
        s.record(question: "Q", answer: "A", source: .live)
        s.end()
        XCTAssertFalse(store().sessions.isEmpty)

        s.clear()
        XCTAssertTrue(store().sessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/sessions.json"))
    }

    /// 面试转录是这些文件里最敏感的一份——「删除本地数据」漏了它，
    /// 那句「将永久删除…」就是假的。
    func testDeleteAllCoversTheSessionLog() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/NotchMeet/Core/LocalData.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("sessions.json"),
                      "LocalData.deleteAll 必须清除面试转录")
    }

    /// 转录仅本用户可读（同 scripts.json / facts.json 的约定）。
    func testLogFileIsOwnerReadableOnly() throws {
        let s = store()
        s.begin(scriptName: nil)
        s.record(question: "Q", answer: "A", source: .live)
        s.end()

        let attrs = try FileManager.default.attributesOfItem(atPath: dir + "/sessions.json")
        XCTAssertEqual(attrs[.posixPermissions] as? NSNumber, 0o600)
    }

    /// 只留最近若干场：复盘看的是最近几家，也限制转录在磁盘上的量。
    func testOldSessionsAreTrimmed() {
        let s = store()
        for i in 0..<25 {
            s.begin(scriptName: "第\(i)场")
            s.record(question: "Q\(i)", answer: "A", source: .live)
            s.end()
        }
        let all = store().sessions
        XCTAssertLessThanOrEqual(all.count, 20)
        XCTAssertEqual(all.first?.scriptName, "第24场", "最新的在最前")
    }

    /// 承诺与实现必须同步：删除清单里有转录，文案里就必须写出来——
    /// 「已删除」的承诺不能建立在用户看不到的差额上。
    func testDeletePromiseMentionsTheSessionLog() {
        for lang in [UILanguage.zh, .ja] {
            let body = AppStrings(language: lang).deleteConfirmBody
            let mentions = body.contains("复盘") || body.contains("振り返り")
            XCTAssertTrue(mentions, "\(lang) 的删除文案没提面试复盘记录，但实际会删掉它")
        }
    }

    // MARK: - Codex review 指出的三处

    /// 只删文件、不清内存 → 复盘页照样列出已删的转录，而下一次 end() 会把内存里
    /// 留存的整份历史写回磁盘：「已删除」当场变成假话。
    func testClearingPreventsDeletedTranscriptsFromBeingWrittenBack() {
        let s = store()
        s.begin(scriptName: "第一场")
        s.record(question: "Q1", answer: "A1", source: .live)
        s.end()
        XCTAssertEqual(store().sessions.count, 1)

        s.clear()                                   // ＝「删除本地数据」时该做的事

        s.begin(scriptName: "第二场")
        s.record(question: "Q2", answer: "A2", source: .live)
        s.end()

        let after = store().sessions
        XCTAssertEqual(after.count, 1, "已删除的场次不得随下一次保存复活")
        XCTAssertEqual(after.first?.scriptName, "第二场")
    }

    /// recall-merge：前置陈述先被定稿记了一轮，随后合并成一问重答。
    /// 不撤回就会一问变两条，把命中率冲淡。
    func testRetractRemovesThePrematurelyRecordedTurn() {
        let s = store()
        s.begin(scriptName: nil)
        s.record(question: "なるほど、そうですか。", answer: "A", source: .live)
        s.retractLast(question: "なるほど、そうですか。")
        s.record(question: "なるほど、そうですか。 では志望動機は？", answer: "B", source: .script)
        s.end()

        let session = try! XCTUnwrap(store().sessions.first)
        XCTAssertEqual(session.turns.count, 1, "合并后应只剩合并那一轮")
        XCTAssertEqual(session.turns.first?.source, .script)
    }

    /// 撤回只针对刚记下的那一条，不能误删别的。
    func testRetractOnlyTouchesTheMatchingLastTurn() {
        let s = store()
        s.begin(scriptName: nil)
        s.record(question: "Q1", answer: "A1", source: .script)
        s.retractLast(question: "别的问题")
        s.end()
        XCTAssertEqual(store().sessions.first?.turns.count, 1)
    }

    /// 退出前的收尾入口必须存在——录音中直接退出不经过 stopRecording。
    func testTerminationHookExists() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let delegate = try String(contentsOf: root.appendingPathComponent("Sources/NotchMeet/App/AppDelegate.swift"),
                                  encoding: .utf8)
        XCTAssertTrue(delegate.contains("applicationWillTerminate"), "缺少退出钩子，录音中退出会丢掉整场复盘")
        XCTAssertTrue(delegate.contains("prepareForTermination"))
    }
}
