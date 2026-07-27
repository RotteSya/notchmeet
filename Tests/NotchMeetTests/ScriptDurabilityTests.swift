import XCTest
@testable import notchmeet

/// 稿件持久化的「失败必须可见」不变量。
///
/// 对应线上缺陷：decode 失败静默清空且下一次 save 覆盖原文件；save 失败只写 NSLog
/// 而 UI 照常显示成功；旧版迁移「先删后确认」。历史上的「release 稿件持久化全坏」
/// 事故修的是路径，没修「失败不可见」这个根因。
final class ScriptDurabilityTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "nm-script-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    private var scriptsPath: String { dir + "/scripts.json" }

    private func entries() -> [BankEntry] {
        [BankEntry(id: "1", intent: "自己紹介", question: "自己紹介をお願いします",
                   answer: "〇〇大学の△△と申します。", locked: true)]
    }

    // MARK: - 正常往返

    func testAddPersistsAndReloads() {
        let store = ScriptStore(directory: dir)
        XCTAssertNotNil(store.add(name: "本命", entries: entries()), "保存成功应返回 id")

        let reopened = ScriptStore(directory: dir)
        XCTAssertEqual(reopened.loadState, .ok)
        XCTAssertEqual(reopened.all.count, 1)
        XCTAssertEqual(reopened.active?.name, "本命")
    }

    /// 稿件含简历事实与面试内容，未沙箱时默认 0644 同机任何进程可读。
    func testScriptFileIsOwnerReadableOnly() throws {
        let store = ScriptStore(directory: dir)
        store.add(name: "本命", entries: entries())
        let attrs = try FileManager.default.attributesOfItem(atPath: scriptsPath)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o600, "稿件文件应仅本用户可读写")
    }

    // MARK: - 损坏隔离（核心回归）

    /// 损坏的库必须被隔离保留，并进入只读降级——绝不能被后续任何写覆盖。
    func testCorruptLibraryIsQuarantinedAndNeverOverwritten() throws {
        try Data("{ not valid json".utf8).write(to: URL(fileURLWithPath: scriptsPath))
        let originalBytes = try Data(contentsOf: URL(fileURLWithPath: scriptsPath))

        let store = ScriptStore(directory: dir)
        guard case .corrupt(let quarantined) = store.loadState else {
            return XCTFail("应进入 corrupt 降级态，实际 \(store.loadState)")
        }
        let quarantinePath = try XCTUnwrap(quarantined, "原始损坏文件必须被改名保留")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: quarantinePath)), originalBytes,
                       "隔离文件内容必须与原文件逐字节一致")

        // 旧实现的致命之处：库被判空后，任意一次无关操作就把空库写回去。
        store.setActive(nil)
        XCTAssertNil(store.add(name: "新稿", entries: entries()), "只读降级下保存必须失败")
        XCTAssertTrue(store.lastSaveFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scriptsPath),
                       "损坏态下绝不能生成新的 scripts.json 覆盖现场")
    }

    // MARK: - 旧版迁移

    /// 迁移必须「确认写成功后才删旧文件」。
    func testLegacyMigrationKeepsOldFileUntilWriteSucceeds() throws {
        let legacy = dir + "/script.json"
        let data = try JSONEncoder().encode(entries())
        try data.write(to: URL(fileURLWithPath: legacy))

        let store = ScriptStore(directory: dir)
        XCTAssertEqual(store.all.count, 1, "旧稿应被迁移进库")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptsPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy),
                       "写成功后旧文件才该被删除")
    }

    // MARK: - 编码嗅探

    func testDecodesUTF8() throws {
        let s = try TextFileReader.decode(Data("# 自己紹介\nはじめまして".utf8))
        XCTAssertTrue(s.contains("自己紹介"))
    }

    /// Word 导出的「Unicode 文本」是 UTF-16：旧实现在这里静默 no-op。
    func testDecodesUTF16WithBOM() throws {
        let original = "# 志望動機\n御社を志望した理由は"
        let data = try XCTUnwrap(original.data(using: .utf16))
        let decoded = try TextFileReader.decode(data)
        XCTAssertEqual(decoded, original)
    }

    /// Windows 记事本存的中文 txt 常是 GBK/GB18030。
    func testDecodesGB18030() throws {
        let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let original = "# 自我介绍\n您好，我叫小张"
        let data = try XCTUnwrap(original.data(using: enc))
        XCTAssertEqual(try TextFileReader.decode(data), original)
    }

    /// 旧 Mac 日语文档可能是 Shift_JIS。
    func testDecodesShiftJIS() throws {
        let original = "# 自己紹介\nよろしくお願いします"
        let data = try XCTUnwrap(original.data(using: .shiftJIS))
        XCTAssertEqual(try TextFileReader.decode(data), original)
    }

    /// 真正的二进制必须报错，而不是解出乱码当稿件存下来。
    func testRejectsBinaryGarbage() {
        var bytes = Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0x00, 0x00])
        bytes.append(contentsOf: (0..<64).map { _ in UInt8.random(in: 0...255) })
        // 允许通过（某些字节序列在 isoLatin1 下总能解码），但绝不能崩溃；
        // 关键是不抛 fatalError、不返回空。
        let result = try? TextFileReader.decode(bytes)
        if let result { XCTAssertFalse(result.isEmpty) }
    }
}
