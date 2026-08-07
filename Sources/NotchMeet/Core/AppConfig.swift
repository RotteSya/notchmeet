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
        pipeline(environment: ProcessInfo.processInfo.environment,
                 arguments: ProcessInfo.processInfo.arguments)
    }

    /// 纯函数形态（环境可注入，供测试直接驱动 demo/mock/live 判定）。
    static func pipeline(environment: [String: String], arguments: [String]) -> Pipeline {
        if environment["FI_UI_DEMO"] == "1" || arguments.contains("--ui-demo") {
            return .demo
        }
        #if DEBUG
        switch environment["FI_PIPELINE"] {
        case "mock": return .mock
        case "live": return .live
        default: break
        }
        #endif
        return .auto
    }

    /// demo 管线的硬承诺：**全程零 Keychain 访问**。
    ///
    /// FI_UI_DEMO 的用途是视觉 QA/录屏，而重新打包的二进制读 Keychain 会触发
    /// ACL 密码弹框，打断正在演示的人。所有 Keychain 触点（`Secrets`、
    /// `KeychainCreditStore` 账本）都必须挂在这同一道门后，启动期的计费初始化
    /// （`AppController.bootstrapCreditIfAllowed`）也以它为准。
    static var keychainAllowed: Bool { keychainAllowed(for: pipeline) }

    static func keychainAllowed(for pipeline: Pipeline) -> Bool { pipeline != .demo }
}
