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
    static var pipeline: Pipeline {
        let process = ProcessInfo.processInfo
        return process.environment["FI_UI_DEMO"] == "1" || process.arguments.contains("--ui-demo")
            ? .demo : .auto
    }
}
