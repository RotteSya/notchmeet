import Foundation

/// Global feature/config flags.
enum AppConfig {
    enum Pipeline {
        case demo   // fake scripted stream (UI-only smoke test)
        case mock   // mock STT + mock LLM (no keys/audio needed)
        case live   // real audio + STT + LLM (requires keys + permissions)
        case auto   // live if a Deepgram key exists (Keychain/env), else mock
    }

    /// Default: key-aware. No keys → mock demo; fill a key in the status-bar menu
    /// → switches to live automatically (and stays live next launch).
    ///
    /// `FI_PIPELINE=mock|live` 强制指定（仅 DEBUG）。在此之前 `.mock`/`.live` 两个
    /// 分支不可达，AppController 里对应的 armPipeline 布线无人走也无人测——读代码的人
    /// 会以为系统有四种运行模式。现在它们由这个开关真正可达。
    static var pipeline: Pipeline {
        let process = ProcessInfo.processInfo
        if process.environment["FI_UI_DEMO"] == "1" || process.arguments.contains("--ui-demo") {
            return .demo
        }
        #if DEBUG
        switch process.environment["FI_PIPELINE"] {
        case "mock": return .mock
        case "live": return .live
        default: break
        }
        #endif
        return .auto
    }
}
