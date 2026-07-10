import CryptoKit
import Foundation

/// 充值码（额度制的「卡密」）：`nmc1.<base64url(JSON)>.<base64url(Ed25519 签名)>`。
///
/// 负载：`{"id":"C-…","min":120,"keys":{…}?,"exp":"2027-12-31"?}`
/// - `id`   唯一码号——账本记录已兑换的 id，本机防重复兑换。
/// - `min`  入账分钟数。
/// - `keys` 可选：随码带入的受管服务 Key（给无出厂配置的公开构建用户激活服务）。
/// - `exp`  可选：兑换截止日（ISO `yyyy-MM-dd`，含当日）。
///
/// 签名覆盖 payload 的原始字节，用开发者的 Ed25519 私钥铸造（scripts/nmtool mint），
/// App 内置公钥验签（`Provisioning.creditPublicKeyB64`）——码不可伪造、改一字节即失效。
/// 与 `nmk1.` 设置码（无签名、只带 Key、不入账）并存：后者是运维后门，前者是商业票据。
struct CreditCodePayload: Codable, Equatable {
    var id: String
    var min: Int
    var keys: [String: String]?
    var exp: String?
}

enum CreditCode {
    static let prefix = "nmc1."

    enum ParseError: Error, Equatable {
        case notACode          // 前缀/结构不对（可能是别的什么，交给下一个解析器）
        case malformed         // 是 nmc1 但负载坏了
        case badSignature      // 验签失败（伪造或损坏）
        case noPublicKey       // 本构建没有验签公钥
        case expired           // 过了兑换截止日
    }

    /// 解析 + 验签 + 有效期检查。`now` 可注入便于测试。
    static func verify(_ raw: String,
                       publicKeyB64: String?,
                       now: Date = Date()) -> Result<CreditCodePayload, ParseError> {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix(prefix) else { return .failure(.notACode) }
        let parts = s.dropFirst(prefix.count).split(separator: ".", maxSplits: 1)
        guard parts.count == 2,
              let payloadData = Base64URL.decode(String(parts[0])),
              let sigData = Base64URL.decode(String(parts[1])) else { return .failure(.malformed) }
        guard let payload = try? JSONDecoder().decode(CreditCodePayload.self, from: payloadData),
              !payload.id.isEmpty, payload.min > 0 else { return .failure(.malformed) }

        guard let pubB64 = publicKeyB64, let pubRaw = Data(base64Encoded: pubB64),
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: pubRaw) else {
            return .failure(.noPublicKey)
        }
        guard pub.isValidSignature(sigData, for: payloadData) else {
            return .failure(.badSignature)
        }

        if let exp = payload.exp {
            guard let deadline = Self.parseDay(exp) else { return .failure(.malformed) }
            // 含当日：截止日 23:59:59（UTC 判定——铸码与验码两端一致即可）。
            if now >= deadline.addingTimeInterval(24 * 3600) { return .failure(.expired) }
        }
        return .success(payload)
    }

    /// 铸码（nmtool 与测试共用；App 本体不带私钥、永不调用）。
    static func mint(_ payload: CreditCodePayload,
                     privateKey: Curve25519.Signing.PrivateKey) -> String? {
        guard let payloadData = try? JSONEncoder().encode(payload),
              let sig = try? privateKey.signature(for: payloadData) else { return nil }
        return prefix + Base64URL.encode(payloadData) + "." + Base64URL.encode(sig)
    }

    private static func parseDay(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)
    }
}
