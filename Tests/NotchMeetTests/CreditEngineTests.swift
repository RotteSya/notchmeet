import CryptoKit
import XCTest
@testable import notchmeet

/// 额度引擎：账本、签名充值码、计量策略、运行时预警——商业化的正确性地基。
final class CreditEngineTests: XCTestCase {
    /// 内存持久层：验证「变更→flush→重开」的往返，而不碰真 Keychain。
    final class MemoryStore: CreditStore {
        var data: Data?
        var saves = 0
        func loadLedger() -> Data? { data }
        func saveLedger(_ d: Data) { data = d; saves += 1 }
    }

    private let testKey = Curve25519.Signing.PrivateKey()
    private var testPubB64: String { testKey.publicKey.rawRepresentation.base64EncodedString() }

    override func tearDown() {
        Provisioning.overrideForTesting = nil
        super.tearDown()
    }

    // MARK: - 账本

    func testWelcomeGrantIsOneTimeOnly() {
        let ledger = CreditLedger(store: MemoryStore())
        XCTAssertTrue(ledger.grantWelcome(seconds: 3600))
        XCTAssertFalse(ledger.grantWelcome(seconds: 3600), "迎新赠礼只能发一次")
        XCTAssertEqual(ledger.balanceSeconds, 3600)
    }

    func testConsumeAndBalanceClampToZero() {
        let ledger = CreditLedger(store: MemoryStore())
        ledger.grantWelcome(seconds: 10)
        ledger.consume(seconds: 25)
        XCTAssertEqual(ledger.balanceSeconds, 0, "余额显示钳到 0，不出现负数")
    }

    func testLedgerRoundTripsThroughStore() {
        let store = MemoryStore()
        let a = CreditLedger(store: store)
        a.grantWelcome(seconds: 3600)
        _ = a.redeem(id: "C-1", seconds: 600)
        a.consume(seconds: 30)
        a.flush()
        let b = CreditLedger(store: store)
        XCTAssertEqual(b.balanceSeconds, 3600 + 600 - 30)
        XCTAssertEqual(b.redeem(id: "C-1", seconds: 600), .alreadyRedeemed, "重开后仍记得已兑换的码")
    }

    func testRedeemSameCodeTwiceRejected() {
        let ledger = CreditLedger(store: MemoryStore())
        XCTAssertEqual(ledger.redeem(id: "C-9", seconds: 60), .ok)
        XCTAssertEqual(ledger.redeem(id: "C-9", seconds: 60), .alreadyRedeemed)
        XCTAssertEqual(ledger.balanceSeconds, 60, "第二次兑换不入账")
    }

    // MARK: - 充值码（签名票据）

    func testMintedCodeVerifies() throws {
        let payload = CreditCodePayload(id: "C-42", min: 120, keys: ["DASHSCOPE_API_KEY": "sk-x"], exp: nil)
        let code = try XCTUnwrap(CreditCode.mint(payload, privateKey: testKey))
        XCTAssertTrue(code.hasPrefix("nmc1."))
        let out = CreditCode.verify(code, publicKeyB64: testPubB64)
        XCTAssertEqual(try out.get(), payload)
    }

    func testTamperedCodeFailsSignature() throws {
        // 改负载的一个字节（min 120 → 999）：签名必须失效。
        let code = try XCTUnwrap(CreditCode.mint(.init(id: "C-1", min: 120, keys: nil, exp: nil),
                                                 privateKey: testKey))
        let parts = code.dropFirst(5).split(separator: ".", maxSplits: 1)
        var json = try XCTUnwrap(Base64URL.decode(String(parts[0])))
        json = Data(String(data: json, encoding: .utf8)!
            .replacingOccurrences(of: "120", with: "999").utf8)
        let forged = "nmc1." + Base64URL.encode(json) + "." + String(parts[1])
        guard case .failure(.badSignature) = CreditCode.verify(forged, publicKeyB64: testPubB64) else {
            return XCTFail("伪造的码必须验签失败")
        }
    }

    func testWrongKeyFailsSignature() throws {
        let code = try XCTUnwrap(CreditCode.mint(.init(id: "C-1", min: 60, keys: nil, exp: nil),
                                                 privateKey: testKey))
        let otherPub = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        guard case .failure(.badSignature) = CreditCode.verify(code, publicKeyB64: otherPub) else {
            return XCTFail("别人的公钥不能验过我们的码")
        }
    }

    func testExpiredCodeRejectedButSameDayAccepted() throws {
        let code = try XCTUnwrap(CreditCode.mint(.init(id: "C-1", min: 60, keys: nil, exp: "2026-07-10"),
                                                 privateKey: testKey))
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")
        // 截止日当天 23 点仍可兑换（含当日）
        let sameDay = f.date(from: "2026-07-10 23:00")!
        XCTAssertNoThrow(try CreditCode.verify(code, publicKeyB64: testPubB64, now: sameDay).get())
        // 次日起过期
        let nextDay = f.date(from: "2026-07-11 00:01")!
        guard case .failure(.expired) = CreditCode.verify(code, publicKeyB64: testPubB64, now: nextDay) else {
            return XCTFail("过了截止日必须拒绝")
        }
    }

    func testNonCodeAndGarbageDistinguished() {
        guard case .failure(.notACode) = CreditCode.verify("nmk1.abc", publicKeyB64: testPubB64) else {
            return XCTFail("nmk1 设置码应报 notACode（交给下一个解析器）")
        }
        guard case .failure(.malformed) = CreditCode.verify("nmc1.!!!.???", publicKeyB64: testPubB64) else {
            return XCTFail("坏 nmc1 应报 malformed")
        }
        guard case .failure(.noPublicKey) = CreditCode.verify(
            CreditCode.mint(.init(id: "C", min: 1, keys: nil, exp: nil), privateKey: testKey)!,
            publicKeyB64: nil) else {
            return XCTFail("无公钥的构建应报 noPublicKey")
        }
    }

    // MARK: - 计量策略

    func testMeteringPolicy() {
        // 受管 LLM → 计量；全 BYO → 免费；纯本地 STT + 无 LLM → 免费。
        XCTAssertTrue(CreditPolicy.isMetered(stt: .apple, llm: .qwen) { $0 == "DASHSCOPE_API_KEY" })
        XCTAssertFalse(CreditPolicy.isMetered(stt: .apple, llm: .qwen) { _ in false })
        XCTAssertTrue(CreditPolicy.isMetered(stt: .deepgram, llm: .none) { $0 == "DEEPGRAM_API_KEY" })
        XCTAssertFalse(CreditPolicy.isMetered(stt: .deepgram, llm: .gemini) { _ in false })
        XCTAssertFalse(CreditPolicy.isMetered(stt: .mock, llm: .none) { _ in true })
        // STT 受管、LLM 自备：仍计量（受管的转写在烧钱）
        XCTAssertTrue(CreditPolicy.isMetered(stt: .deepgram, llm: .claude) { $0 == "DEEPGRAM_API_KEY" })
    }

    // MARK: - 运行时（CreditManager）

    private func makeManager(granted: Int) -> CreditManager {
        let ledger = CreditLedger(store: MemoryStore())
        ledger.grantWelcome(seconds: granted)
        return CreditManager(ledger: ledger)
    }

    func testWelcomeGiftOnlyWithBundledService() {
        Provisioning.overrideForTesting = ProvisioningPayload()   // 无内置服务
        let bare = CreditManager(ledger: CreditLedger(store: MemoryStore()))
        bare.bootstrap()
        XCTAssertEqual(bare.balanceSeconds, 0, "无受管服务的构建不发赠礼")

        Provisioning.overrideForTesting = ProvisioningPayload(keys: ["DASHSCOPE_API_KEY": "sk"],
                                                              pub: nil, buy: nil, gift: 3600)
        let bundled = CreditManager(ledger: CreditLedger(store: MemoryStore()))
        bundled.bootstrap()
        XCTAssertEqual(bundled.balanceSeconds, 3600)
        XCTAssertTrue(bundled.welcomeGrantedThisLaunch)
        bundled.bootstrap()
        XCTAssertEqual(bundled.balanceSeconds, 3600, "重复 bootstrap 不重复发")
    }

    func testTickWarnsAt10And3MinutesOnceEach() {
        let m = makeManager(granted: 601)
        var alerts: [CreditManager.Alert] = []
        m.onAlert = { alerts.append($0) }
        m.beginSession(metered: true)
        m.tick()   // 600s → low(10)
        m.tick()   // 599s → 不再报
        XCTAssertEqual(alerts, [.low(minutesLeft: 10)])
    }

    func testTickFiresExhaustedAtZero() {
        let m = makeManager(granted: 2)
        var alerts: [CreditManager.Alert] = []
        m.onAlert = { alerts.append($0) }
        m.beginSession(metered: true)
        m.tick()   // 1s left → low(3)（低于 3 分钟档）
        m.tick()   // 0 → exhausted
        XCTAssertEqual(alerts, [.low(minutesLeft: 3), .exhausted])
        XCTAssertEqual(m.balanceSeconds, 0)
    }

    func testUnmeteredSessionNeverConsumes() {
        let m = makeManager(granted: 100)
        m.beginSession(metered: false)
        XCTAssertFalse(m.meteringActive)
        XCTAssertEqual(m.balanceSeconds, 100)
        m.endSession()
        XCTAssertEqual(m.balanceSeconds, 100)
    }

    func testRedeemThroughManagerAddsMinutes() throws {
        Provisioning.overrideForTesting = ProvisioningPayload(keys: [:], pub: testPubB64,
                                                              buy: nil, gift: nil)
        let m = makeManager(granted: 0)
        let code = try XCTUnwrap(CreditCode.mint(.init(id: "C-7", min: 30, keys: nil, exp: nil),
                                                 privateKey: testKey))
        XCTAssertEqual(m.redeem(code), .success(minutes: 30, carriesKeys: false))
        XCTAssertEqual(m.balanceSeconds, 30 * 60)
        XCTAssertEqual(m.redeem(code), .alreadyRedeemed)
        XCTAssertEqual(m.redeem("nmk1.e30"), .notACode)
        XCTAssertEqual(m.redeem("nmc1.junk.junk"), .invalid)
    }

    /// scripts/nmtool.swift 铸的真码必须能被 App 验过——两端格式（base64url、签名覆盖
    /// 负载原始字节、JSON 字段）的兼容性由这条「化石」固定：任何一端改了编码就会红。
    func testScriptMintedCodeVerifiesInApp() throws {
        let pub = "WCguaJxbaYBZzmlNLvVSAkalLjWhZJv8fvKzal1Hn0s="
        let code = "nmc1.eyJpZCI6IkMtVEVTVC0xIiwibWluIjoxMjB9.w9dGP-ROH-nf3EoEQzQHY6Z2qsOjcHz-tHkSuv5744dI7hCw5tgCAcA_ytNFsLrStErDecWkEdYsOI1QRWYSCg"
        let payload = try CreditCode.verify(code, publicKeyB64: pub).get()
        XCTAssertEqual(payload.id, "C-TEST-1")
        XCTAssertEqual(payload.min, 120)
        // 同一把工具生成的出厂配置也要能解（xor + base64url 兼容）。
        let nmp = "nmp1.FU9KGRQbVFNAX19eAVRaCxReUkgUVC0yOic9bjlhKzJsIDswPSwqS1VMXh0cGgheBF9eRFpRFENMXQNTTFcPJzEIAwg5EQ0PdDRrFABBPj4ZIDoyAg4CYRxmBjdnBkoJACIJCANfZRgBHVAPDQ"
        let p = try XCTUnwrap(Provisioning.decode(nmp))
        XCTAssertEqual(p.keys["DASHSCOPE_API_KEY"], "sk-test-123")
        XCTAssertEqual(p.gift, 3600)
        XCTAssertEqual(p.pub, pub)
    }

    // MARK: - 出厂配置

    func testProvisioningRoundTrip() throws {
        let p = ProvisioningPayload(keys: ["DEEPGRAM_API_KEY": "dg-1"],
                                    pub: testPubB64, buy: "https://example.com/buy", gift: 1800)
        let encoded = try XCTUnwrap(Provisioning.encode(p))
        XCTAssertTrue(encoded.hasPrefix("nmp1."))
        XCTAssertEqual(Provisioning.decode(encoded), p)
        XCTAssertFalse(encoded.contains("dg-1"), "Key 不能以明文出现在文件里")
        XCTAssertNil(Provisioning.decode("nmp1.corrupted!!"))
        XCTAssertNil(Provisioning.decode("nmk1.e30"))
    }
}
