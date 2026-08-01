import Foundation

/// One-click privacy wipe (PLAN §10): facts, answer bank, user script, and API keys.
enum LocalData {
    /// Every Keychain key any provider reads via `Settings.apiKey` — the wipe must
    /// cover them all, or "delete my data" leaves credentials behind.
    static let managedSecretKeys = [
        "DEEPGRAM_API_KEY", "GEMINI_API_KEY", "ANTHROPIC_API_KEY",
        "DEEPSEEK_API_KEY", "DASHSCOPE_API_KEY",
    ]

    /// 返回未能删除的项目（空 = 全部清除干净）。调用方必须据此告知用户——
    /// 「已删除」的承诺不能建立在被吞掉的错误上。
    @discardableResult
    static func deleteAll() -> [String] {
        var failures: [String] = []
        let fm = FileManager.default
        // Knowledge files: the resolved dir (App Support in release, ./knowledge in dev)
        // plus the legacy cwd-relative location older builds wrote to.
        var dirs = [KnowledgePaths.dir,
                    fm.currentDirectoryPath + "/knowledge"]
        if let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            dirs.append(appSup.appendingPathComponent("notchmeet").path)
        }
        for dir in Set(dirs) {
            // sessions.json = 面试转录，是这些文件里最敏感的一份，绝不能漏。
            for f in ["facts.json", "answer_bank.json", "scripts.json", "script.json",
                      "sessions.json"] {
                let p = dir + "/" + f
                guard fm.fileExists(atPath: p) else { continue }
                do { try fm.removeItem(atPath: p) } catch {
                    failures.append(f)
                    NSLog("[privacy] delete FAILED %@: %@", p, String(describing: error))
                }
            }
            // 隔离下来的损坏稿件同样含用户内容，一并清除。
            if let leftovers = try? fm.contentsOfDirectory(atPath: dir) {
                for f in leftovers where f.hasPrefix("scripts.json.corrupt-") {
                    try? fm.removeItem(atPath: dir + "/" + f)
                }
            }
        }
        for k in managedSecretKeys {
            Secrets.delete(k)
            ManagedKeyRegistry.mark(k, value: nil, managed: false)   // Key 没了，受管登记也不能留
            if let still = Secrets.get(k), !still.isEmpty { failures.append(k) }
        }
        // 有意不动额度账本（com.notchmeet.credit）与兑换日志（.redemptions.json）：
        // 删除隐私数据 ≠ 清空花钱买的余额，也不该把「这张码用过了」的记录一并抹掉。
        if failures.isEmpty {
            NSLog("[privacy] local data deleted")
        } else {
            NSLog("[privacy] local data deletion INCOMPLETE: %@", failures.joined(separator: ", "))
        }
        return failures
    }
}
