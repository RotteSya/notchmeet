import Foundation

/// 出厂内置的「受管服务」配置——商业分发的关键：用户安装后**零配置**就能用，
/// 服务成本由额度制（`CreditLedger`）计量回收。
///
/// 配置以 `provisioning.nmp` 资源文件的形式在打包时注入 .app（见 scripts/provision 工具与
/// release.sh），**不进公开仓库**——与 Knowledge 私有引擎同一套「公开外壳＋私有资产」模式。
/// 文件内容 = `nmp1.` + base64url(XOR(JSON))：XOR 只是防 `strings` 直读的混淆，不是加密；
/// 真正的商业防线是内置 Key 本身是**限速、限额、可轮换**的服务端配置 + 额度计量。
///
/// JSON 负载：
/// ```json
/// { "keys":  { "DASHSCOPE_API_KEY": "sk-…", "DEEPGRAM_API_KEY": "…" },
///   "pub":   "<base64 Ed25519 raw public key —— 充值码验签公钥>",
///   "buy":   "https://…（购买充值码的页面）",
///   "gift":  3600 }                                    // 迎新赠礼秒数（默认 3600 = 60 分钟）
/// ```
struct ProvisioningPayload: Codable, Equatable {
    var keys: [String: String] = [:]
    var pub: String?
    var buy: String?
    var gift: Int?
}

enum Provisioning {
    static let filePrefix = "nmp1."
    /// 混淆用 XOR 密钥（公开仓库可见——它防的是磁盘上的 `strings`，不是逆向）。
    static let xorKey: [UInt8] = Array("nm-provision-v1".utf8)

    /// 测试/开发注入：优先于捆绑资源。`FI_PROVISIONING` 环境变量直接给 `nmp1.…` 串。
    nonisolated(unsafe) static var overrideForTesting: ProvisioningPayload?

    /// 解析后的出厂配置；无资源文件（开发运行 / 公开构建）时为空载荷。
    static var current: ProvisioningPayload {
        if let injected = overrideForTesting { return injected }
        return cached
    }

    private static let cached: ProvisioningPayload = {
        if let raw = ProcessInfo.processInfo.environment["FI_PROVISIONING"],
           let p = decode(raw) { return p }
        guard let url = Bundle.main.url(forResource: "provisioning", withExtension: "nmp"),
              let raw = try? String(contentsOf: url, encoding: .utf8),
              let p = decode(raw) else { return ProvisioningPayload() }
        NSLog("[provision] bundled service present (%d keys)", p.keys.count)
        return p
    }()

    /// 是否存在出厂内置服务（决定迎新赠礼是否发放、开箱是否即用）。
    static var hasService: Bool { !current.keys.isEmpty }

    /// 内置服务里名为 `name` 的 Key（受管来源）。
    static func serviceKey(_ name: String) -> String? {
        guard let v = current.keys[name], !v.isEmpty else { return nil }
        return v
    }

    /// 充值码验签公钥（base64 raw Ed25519）。无出厂配置时用编译期默认值，
    /// 让公开构建的用户拿到开发者手工发的充值码也能兑换。
    static var creditPublicKeyB64: String? { current.pub ?? defaultCreditPublicKeyB64 }

    /// 编译期兜底公钥（2026-07-12 生成的正式签名密钥对；私钥在开发者本机 ~/.notchmeet/，
    /// 官方服务端持同一私钥铸码）。有它在，即使无出厂配置的构建也能兑换官方充值码。
    static let defaultCreditPublicKeyB64: String? = "25JYcx6pyZJ7sibm8YD+onxuRwqsAWdlgrdJ8pl2fLc="

    /// 购买充值码的页面（官方商店：Stripe 收款 → 即时发码）。
    static var buyURL: URL {
        if let s = current.buy, let u = URL(string: s) { return u }
        return URL(string: "https://notchmeet-store.vercel.app")!
    }

    /// 迎新赠礼秒数（默认 60 分钟）。
    static var welcomeGiftSeconds: Int { current.gift ?? 3600 }

    // MARK: - 编解码（与 scripts/nmtool 保持一致）

    static func decode(_ raw: String) -> ProvisioningPayload? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix(filePrefix) else { return nil }
        guard let data = Base64URL.decode(String(s.dropFirst(filePrefix.count))) else { return nil }
        let plain = xor(data)
        return try? JSONDecoder().decode(ProvisioningPayload.self, from: plain)
    }

    static func encode(_ payload: ProvisioningPayload) -> String? {
        guard let json = try? JSONEncoder().encode(payload) else { return nil }
        return filePrefix + Base64URL.encode(xor(json))
    }

    static func xor(_ data: Data) -> Data {
        Data(data.enumerated().map { i, b in b ^ xorKey[i % xorKey.count] })
    }
}

/// base64url（无填充）——setup 码、充值码、出厂配置共用。
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return Data(base64Encoded: b64)
    }
}
