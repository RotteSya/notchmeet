import Combine

/// Observable state the notch renders. Mutated on the main thread by the pipeline.
/// `ObservableObject` / `@Published` are Combine types — the notch is pure AppKit and observes
/// this via `objectWillChange`, no SwiftUI involved.
final class AnswerModel: ObservableObject {
    /// `ready` = armed but NOT capturing (nothing leaves the machine). `listening` and the
    /// AI-working states (`thinking`/`streaming`/`presenting`) only occur while recording.
    enum Status: Equatable { case ready, listening, thinking, streaming, presenting, error }

    @Published var expanded = false
    @Published var status: Status = .ready
    @Published var message: RuntimeMessage = .ready
    /// True only while the audio tap is live and audio is being uploaded. Drives the
    /// unmistakable "REC" treatment (red outline) independent of the activity `status`.
    @Published var recording = false
    @Published var answer = ""          // verbatim user script or streamed spoken answer
    @Published var errorDetail: String?
    @Published var intentLabel = ""     // matched/predicted intent — glance-check against mis-match
    @Published var question = ""        // interviewer's question as recognized by STT — glance-check for mis-hearing
}

/// Single display contract for the notch. Non-empty answers are returned byte-for-byte:
/// user scripts are never parsed as Markdown, trimmed, split, numbered, or rewritten.
enum NotchPresentation {
    static func text(answer: String,
                     message: RuntimeMessage,
                     errorDetail: String?,
                     strings: AppStrings) -> String {
        if !answer.isEmpty { return answer }
        if message == .generationError, let errorDetail {
            return strings.generationError(errorDetail)
        }
        if message == .sttError, let errorDetail { return errorDetail }  // SttError.localizedDescription is a full localized sentence
        return strings.runtimeMessage(message)
    }
}
