import Foundation

/// Everything the generator needs for one answer.
struct GenRequest {
    let question: String
    let context: String   // structured-fact / resume grounding (Phase 1)
    let history: String   // recent Q + prior *suggested* answers for 深掘り dedup; not verbatim candidate speech
}

/// Streams a natural, speakable answer as text deltas. Cancellation is via the surrounding Task
/// (Task.cancel()); implementations must honor Task.checkCancellation(). (PLAN §5.)
protocol AnswerGenerator: AnyObject {
    func generate(_ req: GenRequest, epoch: Int,
                  onDelta: @escaping (String) -> Void) async throws
}

/// Last-resort contract enforcement for AI output only. Providers occasionally ignore
/// formatting instructions and emit bullets or Markdown. Normalize those markers before
/// anything reaches the notch; user-authored scripts never pass through this type.
enum SpokenAnswerFormatter {
    /// 预编译一次。旧实现用 `replacingOccurrences(options: .regularExpression)`，
    /// 每一行、每一次调用都重新编译一遍 NSRegularExpression —— 而流式期每个 delta
    /// 都会对**整个** liveBuffer 重跑 normalize，叠加起来是主线程上的 O(n²)。
    private static let leadMarker = try? NSRegularExpression(
        pattern: #"^(?:[-*+•・]\s*|[0-9０-９]+[.)．、]\s*|#{1,6}\s*)"#)

    private static func stripLeadMarker(_ s: String) -> String {
        guard let re = leadMarker else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }

    static func normalize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .compactMap { line -> String? in
                var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                text = stripLeadMarker(text)
                for marker in ["**", "__", "`"] {
                    text = text.replacingOccurrences(of: marker, with: "")
                }
                return text.isEmpty ? nil : text
            }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
