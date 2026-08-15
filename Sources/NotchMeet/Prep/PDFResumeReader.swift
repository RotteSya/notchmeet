import Foundation
import PDFKit
import UniformTypeIdentifiers
import Vision

/// PDF 简历读取：PDFKit 逐页取文本；整份 PDF 几乎无文字（扫描件/纯图导出）时
/// 回落 Vision 离线 OCR（中/日/英）。全程系统框架，零新依赖、不出网。
///
/// OCR 是 CPU 重活（每页一次识别请求），不要在主线程调用。
enum PDFResumeReader: ResumeReader {
    enum ReadError: Error, LocalizedError {
        case unreadable
        case encrypted
        case noText

        var errorDescription: String? {
            switch self {
            case .unreadable: return AppStrings.current.importUnreadable
            case .encrypted:  return AppStrings.current.importPDFEncrypted
            case .noText:     return AppStrings.current.importPDFNoText
            }
        }
    }

    static var supportedTypes: [UTType] { [.pdf] }

    /// 文本层字符总数低于这个数时判定为「扫描件」，整份走 OCR。
    /// （一页正常简历的文本层就有数百字；40 字以下只可能是页眉水印之类。）
    static let ocrThreshold = 40
    /// OCR 页数上限：简历超过这个页数的部分不识别（成本封顶；正常简历 1-3 页）。
    static let maxOCRPages = 12

    static func read(url: URL) throws -> ResumeDocument {
        guard let doc = PDFDocument(url: url) else { throw ReadError.unreadable }
        // isLocked = 需要密码才能打开；isEncrypted 且已解锁（空密码）的可以继续读。
        if doc.isLocked { throw ReadError.encrypted }

        var pages: [(page: Int, text: String)] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { pages.append((i + 1, text)) }
        }

        let totalChars = pages.reduce(0) { $0 + $1.text.count }
        if totalChars < ocrThreshold {
            pages = ocrPages(doc)
            guard !pages.isEmpty else { throw ReadError.noText }
        }

        return document(from: pages, sourceName: url.lastPathComponent)
    }

    /// 纯函数：页文本 → ResumeDocument（段落切块，便于测试）。
    static func document(from pages: [(page: Int, text: String)],
                         sourceName: String) -> ResumeDocument {
        var blocks: [ResumeTextBlock] = []
        var full: [String] = []
        for (pageNo, text) in pages {
            full.append(text)
            let paragraphs = text
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for p in paragraphs {
                blocks.append(ResumeTextBlock(index: blocks.count, text: p, page: pageNo))
            }
        }
        return ResumeDocument(sourceName: sourceName,
                              plainText: full.joined(separator: "\n\n"),
                              blocks: blocks)
    }

    // MARK: - OCR fallback（扫描件）

    private static func ocrPages(_ doc: PDFDocument) -> [(page: Int, text: String)] {
        var out: [(Int, String)] = []
        for i in 0..<min(doc.pageCount, maxOCRPages) {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            // 2x 渲染：Vision 对小字号的识别率对分辨率敏感，1x 的 10pt 字常读错。
            let scale: CGFloat = 2
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let image = page.thumbnail(of: size, for: .mediaBox)
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "ja-JP", "en-US"]
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cg)
            guard (try? handler.perform([request])) != nil,
                  let observations = request.results else { continue }
            let text = observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out.append((i + 1, text)) }
        }
        if !out.isEmpty {
            NSLog("[resume] OCR fallback recognized %d pages", out.count)
        }
        return out
    }
}
