import Foundation
import UniformTypeIdentifiers

/// 简历文档的读取抽象（模块 C 的格式接缝）。每种格式一个 reader，上层只见
/// `ResumeDocument`——纯文本 + 定位块，定位块供出处引用（provenance）回溯。
/// docx（zip 容器，Foundation 无公开解包 API）暂不实现：未来加一个 reader
/// 文件即可接入，不动任何上层。
protocol ResumeReader {
    static var supportedTypes: [UTType] { get }
    static func read(url: URL) throws -> ResumeDocument
}

/// 一个可定位的文本块（段落级）。PDF 有页码，纯文本没有。
struct ResumeTextBlock {
    let index: Int
    let text: String
    let page: Int?
}

/// 上层唯一消费的简历形态。`plainText` 供 LLM 抽取与对齐校验，
/// `blocks` 供 UI 显示「读到 N 个区块」的即时反馈。
struct ResumeDocument {
    let sourceName: String
    let plainText: String
    let blocks: [ResumeTextBlock]
}

/// 纯文本 / Markdown 简历：直接走既有的多编码读取兜底。
enum TextResumeReader: ResumeReader {
    static var supportedTypes: [UTType] {
        var types: [UTType] = [.plainText, .text]
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        if let markdown = UTType(filenameExtension: "markdown") { types.append(markdown) }
        return types
    }

    static func read(url: URL) throws -> ResumeDocument {
        let text = try TextFileReader.read(url)
        return document(from: text, sourceName: url.lastPathComponent)
    }

    /// 纯函数，便于测试与「粘贴正文」入口复用。
    static func document(from text: String, sourceName: String) -> ResumeDocument {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // 段落 = 连续非空行。单个换行在导出的简历里往往只是排版，不是语义边界。
        let paragraphs = normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let blocks = paragraphs.enumerated().map {
            ResumeTextBlock(index: $0.offset, text: $0.element, page: nil)
        }
        return ResumeDocument(sourceName: sourceName, plainText: normalized, blocks: blocks)
    }
}

/// 按扩展名分发到对应 reader。上层（工作台 / 引导）只调这一个入口。
enum ResumeReaders {
    /// 文件选择面板的 allowedContentTypes（文本 + Markdown + PDF）。
    static var openPanelTypes: [UTType] {
        TextResumeReader.supportedTypes + PDFResumeReader.supportedTypes
    }

    /// 可能做 OCR（CPU 重），不要在主线程调用。
    static func read(url: URL) throws -> ResumeDocument {
        if url.pathExtension.lowercased() == "pdf" {
            return try PDFResumeReader.read(url: url)
        }
        return try TextResumeReader.read(url: url)
    }
}
