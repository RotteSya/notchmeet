import Foundation

/// 兑换与赠礼的**第二处**记录，独立于 Keychain 账本。
///
/// 账本只存在 Keychain 里时，一条 `security delete-generic-password -s
/// com.notchmeet.credit` 就把 `welcomeGranted` 与 `redeemedCodeIDs` 一并清空：
/// 迎新赠礼可以反复领，历史买过的每一张充值码都能再兑一次。更糟的是充值码本身没有
/// 机器绑定，一张贴到论坛的码任何人都能兑、且每人可无限次。
///
/// 没有服务器就没有真正的防重放，但把「见过哪些码」写到第二个位置（App Support），
/// 并在两处**取并集**判定，可以把绕过成本从「删一条钥匙串」提高到「同时找到并清理
/// 两处状态」。任一处见过即拒绝——这才是防重放该有的方向。
///
/// 真正的解法是在商店侧做一次性激活登记（code → 已兑换机器）；<20 人规模完全负担得起。
enum RedemptionJournal {
    /// 测试注入点：默认写 App Support。测试必须指向临时目录，否则会污染开发机的
    /// 真实兑换记录，并在用例之间互相泄漏状态。
    nonisolated(unsafe) static var overridePath: String?

    private static var path: String {
        if let overridePath { return overridePath }
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.path ?? NSTemporaryDirectory()
        return dir + "/notchmeet/.redemptions.json"
    }

    private struct State: Codable {
        var codeIDs: [String] = []
        var welcomeGranted = false

        init() {}

        /// 手写解码，理由同 `CreditLedgerState`：合成解码器不使用默认值。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            codeIDs = try c.decodeIfPresent([String].self, forKey: .codeIDs) ?? []
            welcomeGranted = try c.decodeIfPresent(Bool.self, forKey: .welcomeGranted) ?? false
        }
    }

    private static func load() -> State {
        guard let data = FileManager.default.contents(atPath: path),
              let s = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return s
    }

    private static func save(_ s: State) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// 这张码在本机是否已经兑换过（第二处记录）。
    static func hasRedeemed(_ id: String) -> Bool {
        load().codeIDs.contains(id)
    }

    static func noteRedeemed(_ id: String) {
        var s = load()
        guard !s.codeIDs.contains(id) else { return }
        s.codeIDs.append(id)
        // 只保留最近 500 条，避免无限增长（正常用户远达不到）。
        if s.codeIDs.count > 500 { s.codeIDs.removeFirst(s.codeIDs.count - 500) }
        save(s)
    }

    static var welcomeGranted: Bool { load().welcomeGranted }

    static func noteWelcomeGranted() {
        var s = load()
        guard !s.welcomeGranted else { return }
        s.welcomeGranted = true
        save(s)
    }
}
