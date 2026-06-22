import Foundation

/// Streams a canned, directly speakable answer so the pipeline runs without an LLM key.
final class MockAnswerGenerator: AnswerGenerator {
    func generate(_ req: GenRequest, epoch: Int, onDelta: @escaping (String) -> Void) async throws {
        try await Task.sleep(nanoseconds: 400_000_000) // simulate TTFT
        let answer = "はい。私の強みは、状況を整理してすぐに行動へ移せる点です。学生時代には周囲と協力しながら課題を見つけ、改善を積み重ねて成果につなげました。御社でもこの経験を活かし、相手の期待を丁寧に捉えながら着実に貢献したいと考えています。"
        for ch in answer {
            try Task.checkCancellation()
            onDelta(String(ch))
            try await Task.sleep(nanoseconds: 8_000_000)
        }
    }
}
