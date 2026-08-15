import XCTest
@testable import notchmeet

private let sampleResume = """
# 张三

后端工程师，3 年分布式系统经验。

## 工作经历

星云数据 · 后端开发 · 2022.07-2025.06
负责订单链路的缓存改造，把热点 Key 从 MySQL 迁到 Redis，
接口 P99 从 240ms 降到 40ms。

## 专业技能

Go / Redis / MySQL / Kubernetes

## 求职意向

期望从事基础设施方向，目标公司：北极星。

期望薪资：30 万
"""

final class ResumeReaderTests: XCTestCase {
    func testTextDocumentSplitsParagraphBlocks() {
        let doc = TextResumeReader.document(from: sampleResume, sourceName: "张三.md")
        XCTAssertEqual(doc.sourceName, "张三.md")
        XCTAssertGreaterThanOrEqual(doc.blocks.count, 5)
        XCTAssertTrue(doc.plainText.contains("星云数据"))
        XCTAssertNil(doc.blocks[0].page)
    }

    func testWindowsLineEndingsAreNormalized() {
        let doc = TextResumeReader.document(from: "第一段\r\n\r\n第二段", sourceName: "a.txt")
        XCTAssertEqual(doc.blocks.map(\.text), ["第一段", "第二段"])
    }

    func testPDFDocumentCarriesPageNumbers() {
        let doc = PDFResumeReader.document(
            from: [(1, "第一页内容"), (2, "第二页内容\n\n第二页第二段")], sourceName: "简历.pdf")
        XCTAssertEqual(doc.blocks.count, 3)
        XCTAssertEqual(doc.blocks[0].page, 1)
        XCTAssertEqual(doc.blocks[2].page, 2)
        XCTAssertTrue(doc.plainText.contains("第一页内容"))
    }
}

final class ResumeSectionizeTests: XCTestCase {
    func testSectionizeFindsKnownHeadings() {
        let doc = TextResumeReader.document(from: sampleResume, sourceName: "张三.md")
        let sections = ResumeExtractor.sectionize(doc)
        let titles = sections.compactMap(\.title)
        XCTAssertTrue(titles.contains("工作经历"), "titles: \(titles)")
        XCTAssertTrue(titles.contains("专业技能"))
        XCTAssertTrue(titles.contains("求职意向"))
        // 正文行绝不能被吞：分节只是切块，不是过滤。
        XCTAssertTrue(sections.contains { $0.body.contains("星云数据") })
    }

    func testHeadingHeuristics() {
        XCTAssertEqual(ResumeExtractor.headingText("## 项目经历"), "项目经历")
        XCTAssertEqual(ResumeExtractor.headingText("【技能】"), "技能")
        XCTAssertEqual(ResumeExtractor.headingText("教育背景："), "教育背景")
        XCTAssertEqual(ResumeExtractor.headingText("職務経歴"), "職務経歴")
        XCTAssertEqual(ResumeExtractor.headingText("Skills"), "Skills")
        // 普通正文短行不得误判成标题。
        XCTAssertNil(ResumeExtractor.headingText("负责后端开发。"))
        XCTAssertNil(ResumeExtractor.headingText("把热点 Key 迁到 Redis"))
    }

    func testDeterministicNeverFabricatesFacts() {
        let doc = TextResumeReader.document(from: sampleResume, sourceName: "张三.md")
        let r = ResumeExtractor.deterministic(doc)
        // 离线路径只给分节底稿——结构化事实的确认权在用户，机器不编。
        XCTAssertTrue(r.sheet.experiences.isEmpty)
        XCTAssertFalse(r.sections.isEmpty)
        XCTAssertFalse(r.usedLLM)
    }
}

final class ResumeParseExtractionTests: XCTestCase {
    private var doc: ResumeDocument {
        TextResumeReader.document(from: sampleResume, sourceName: "张三.md")
    }

    func testAlignedSrcBecomesProvenanceQuote() throws {
        let raw = """
        {"profile":{"text":"3 年分布式后端工程师","src":"后端工程师，3 年分布式系统经验。"},
         "experiences":[{"role":"后端开发","org":"星云数据","period":"2022.07-2025.06",
           "actions":["把热点 Key 从 MySQL 迁到 Redis"],"results":["接口 P99 从 240ms 降到 40ms"],
           "skills":["Redis","MySQL"],"src":"把热点 Key 从 MySQL 迁到 Redis"}],
         "motivations":[{"company":"北极星","statement":"期望从事基础设施方向","axis":"",
           "src":"期望从事基础设施方向，目标公司：北极星"}],
         "notes":[{"text":"期望薪资 30 万","src":"期望薪资：30 万"}]}
        """
        let (sheet, uncertain) = try XCTUnwrap(ResumeExtractor.parseExtraction(raw, doc: doc))
        XCTAssertEqual(sheet.experiences.count, 1)
        let exp = sheet.experiences[0]
        XCTAssertEqual(exp.org, "星云数据")
        XCTAssertEqual(exp.provenance?.source, "张三.md")
        XCTAssertNotNil(exp.provenance?.quote, "aligned src must survive as the provenance quote")
        XCTAssertEqual(exp.locked, nil, "extracted facts are drafts — confirmation belongs to the user")
        XCTAssertEqual(sheet.motivations[0].targetCompany, "北极星")
        XCTAssertEqual(sheet.notes, ["期望薪资 30 万"])
        XCTAssertEqual(uncertain, 0)
    }

    /// src 对不齐 → 低置信（quote=nil）但不丢弃：弹药面板显示「AI 不确定，请补全」。
    func testUnalignedSrcIsKeptAsUncertain() throws {
        let raw = """
        {"experiences":[{"role":"后端开发","org":"星云数据","period":"2022-2025",
          "actions":[],"results":[],"skills":[],"src":"这句话不在原文里"}]}
        """
        let (sheet, uncertain) = try XCTUnwrap(ResumeExtractor.parseExtraction(raw, doc: doc))
        XCTAssertEqual(sheet.experiences.count, 1)
        XCTAssertNil(sheet.experiences[0].provenance?.quote)
        XCTAssertEqual(sheet.experiences[0].provenance?.source, "张三.md")
        XCTAssertEqual(uncertain, 1)
    }

    /// notes 是 [String]、无 provenance 可挂：对不齐直接丢弃，绝不带病收录。
    func testUnalignedNoteIsDropped() throws {
        let raw = """
        {"notes":[{"text":"编造的事实","src":"原文里没有这句"},
                  {"text":"期望薪资 30 万","src":"期望薪资：30 万"}]}
        """
        let (sheet, _) = try XCTUnwrap(ResumeExtractor.parseExtraction(raw, doc: doc))
        XCTAssertEqual(sheet.notes, ["期望薪资 30 万"])
    }

    func testGarbageAndEmptyOutputRejected() {
        XCTAssertNil(ResumeExtractor.parseExtraction("好的，我来帮你分析简历……", doc: doc))
        XCTAssertNil(ResumeExtractor.parseExtraction(#"{"experiences":[]}"#, doc: doc))
        XCTAssertNil(ResumeExtractor.parseExtraction(
            #"{"experiences":[{"role":"","org":"","src":""}]}"#, doc: doc),
            "empty role+org rows must not count as output")
    }

    /// 抽取整体失败时 extract() 必须退回离线分段（注入的 transport 抛错模拟网络失败）。
    func testExtractFallsBackToDeterministicOnLLMFailure() async {
        struct Boom: Error {}
        let r = await ResumeExtractor.extract(doc, complete: { _, _ in throw Boom() })
        XCTAssertFalse(r.usedLLM)
        XCTAssertTrue(r.sheet.experiences.isEmpty)
        XCTAssertFalse(r.sections.isEmpty, "sections must survive as the manual-curation fallback")
    }

    func testExtractAcceptsInjectedTransport() async {
        let raw = """
        {"experiences":[{"role":"后端开发","org":"星云数据","period":"2022-2025",
          "actions":["缓存改造"],"results":[],"skills":["Redis"],
          "src":"负责订单链路的缓存改造"}]}
        """
        let r = await ResumeExtractor.extract(doc, complete: { _, _ in raw })
        XCTAssertTrue(r.usedLLM)
        XCTAssertEqual(r.sheet.experiences.first?.org, "星云数据")
        XCTAssertNotNil(r.sheet.experiences.first?.provenance?.quote)
    }
}
