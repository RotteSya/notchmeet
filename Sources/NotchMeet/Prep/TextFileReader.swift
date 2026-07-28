import Foundation

/// 稿件文件读取。用户拖进来的东西并不总是 UTF-8——Word 导出的「Unicode 文本」是
/// UTF-16，Windows 记事本的中文 txt 常是 GBK，旧 Mac 文档可能是 Shift_JIS。
///
/// 旧实现三处都写 `try? String(contentsOf:encoding:.utf8)`，失败即静默 no-op：
/// 用户选完文件，什么都没发生，也没有任何错误——最令人困惑的一类失败。
enum TextFileReader {
    enum ReadError: Error, LocalizedError {
        case unreadable
        case unknownEncoding

        var errorDescription: String? {
            switch self {
            case .unreadable:      return AppStrings.current.importUnreadable
            case .unknownEncoding: return AppStrings.current.importUnknownEncoding
            }
        }
    }

    /// 按 UTF-8 → 系统嗅探 → 常见东亚编码的顺序尝试。
    static func read(_ url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else { throw ReadError.unreadable }
        return try decode(data)
    }

    static func read(path: String) throws -> String {
        try read(URL(fileURLWithPath: path))
    }

    /// 纯函数，便于测试。
    static func decode(_ data: Data) throws -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        // 系统嗅探（会读 BOM，覆盖 UTF-16/UTF-32 的两种字节序）。
        var converted: NSString?
        let raw = NSString.stringEncoding(for: data, encodingOptions: nil,
                                          convertedString: &converted,
                                          usedLossyConversion: nil)
        if raw != 0, let s = converted as String? { return s }
        // 兜底：BOM 缺失的东亚编码，系统嗅探常判不出。
        let fallbacks: [String.Encoding] = [
            .utf16, .utf16LittleEndian, .utf16BigEndian,
            .shiftJIS, .japaneseEUC,
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
            .isoLatin1,
        ]
        for enc in fallbacks {
            if let s = String(data: data, encoding: enc), !s.isEmpty { return s }
        }
        throw ReadError.unknownEncoding
    }
}
