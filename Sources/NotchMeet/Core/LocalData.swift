import Foundation

/// One-click privacy wipe (PLAN §10): facts, answer bank, user script, and API keys.
enum LocalData {
    /// Every Keychain key any provider reads via `Settings.apiKey` — the wipe must
    /// cover them all, or "delete my data" leaves credentials behind.
    static let managedSecretKeys = [
        "DEEPGRAM_API_KEY", "GEMINI_API_KEY", "ANTHROPIC_API_KEY",
        "DEEPSEEK_API_KEY", "DASHSCOPE_API_KEY",
    ]

    static func deleteAll() {
        let fm = FileManager.default
        // Knowledge files: the resolved dir (App Support in release, ./knowledge in dev)
        // plus the legacy cwd-relative location older builds wrote to.
        var dirs = [KnowledgePaths.dir,
                    fm.currentDirectoryPath + "/knowledge"]
        if let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            dirs.append(appSup.appendingPathComponent("notchmeet").path)
        }
        for dir in Set(dirs) {
            for f in ["facts.json", "answer_bank.json", "scripts.json", "script.json"] {
                try? fm.removeItem(atPath: dir + "/" + f)
            }
        }
        for k in managedSecretKeys {
            Secrets.delete(k)
            Settings.markKeyManaged(k, false)   // Key 没了，受管标记也不能留
        }
        // 有意不动额度账本（com.notchmeet.credit）：删除隐私数据 ≠ 清空花钱买的余额。
        NSLog("[privacy] local data deleted")
    }
}
