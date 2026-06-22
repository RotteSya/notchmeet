import Foundation

/// One-click privacy wipe (PLAN §10): facts, answer bank, user script, and API keys.
enum LocalData {
    static func deleteAll() {
        let cwd = FileManager.default.currentDirectoryPath
        let fm = FileManager.default
        for p in ["\(cwd)/knowledge/facts.json",
                  "\(cwd)/knowledge/answer_bank.json",
                  "\(cwd)/knowledge/scripts.json",
                  "\(cwd)/knowledge/script.json"] {   // legacy single-script file
            try? fm.removeItem(atPath: p)
        }
        if let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? fm.removeItem(at: appSup.appendingPathComponent("notchmeet"))
        }
        for k in ["DEEPGRAM_API_KEY", "GEMINI_API_KEY", "ANTHROPIC_API_KEY"] { Secrets.delete(k) }
        NSLog("[privacy] local data deleted")
    }
}
