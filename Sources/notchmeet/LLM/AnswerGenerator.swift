import Foundation

/// Everything the generator needs for one answer.
struct GenRequest {
    let question: String
    let context: String   // structured-fact / resume grounding (Phase 1)
    let history: String   // conversation context for 深掘り (Phase 3)
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
    static func normalize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .compactMap { line -> String? in
                var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                text = text.replacingOccurrences(
                    of: #"^(?:[-*+•・]\s*|[0-9０-９]+[.)．、]\s*|#{1,6}\s*)"#,
                    with: "",
                    options: .regularExpression
                )
                for marker in ["**", "__", "`"] {
                    text = text.replacingOccurrences(of: marker, with: "")
                }
                return text.isEmpty ? nil : text
            }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
