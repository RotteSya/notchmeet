import XCTest
@testable import notchmeet

/// 受管判定的回归锁：计费的唯一输入是「这个 Key 是不是我们发的」，
/// 而这个答案必须落在用户改不动的地方。
///
/// 旧实现把它存在 UserDefaults(`nm_key_managed_*`)，于是有两条零成本免计量路径：
/// 一是 `defaults write … -bool false`；二是设置页密钥行预填了真实 Key，
/// 用户一个字不改点「保存」就会执行 markKeyManaged(name, false)。
final class ManagedKeyFingerprintTests: XCTestCase {

    /// 内存指纹库，避免测试碰真钥匙串。
    final class MemoryFingerprintStore: ManagedFingerprintStore {
        var fingerprints: [String: String] = [:]
        var failWrites = false
        func managedFingerprint(for name: String) -> String? { fingerprints[name] }
        @discardableResult
        func setManagedFingerprint(_ fingerprint: String?, for name: String) -> Bool {
            guard !failWrites else { return false }
            if let fingerprint { fingerprints[name] = fingerprint }
            else { fingerprints.removeValue(forKey: name) }
            return true
        }
    }

    private var store: MemoryFingerprintStore!
    private let keyName = "DASHSCOPE_API_KEY"

    override func setUp() {
        super.setUp()
        store = MemoryFingerprintStore()
        ManagedKeyRegistry.store = store
    }

    override func tearDown() {
        ManagedKeyRegistry.store = CreditManager.shared
        Provisioning.overrideForTesting = nil
        super.tearDown()
    }

    // MARK: - 指纹本身

    func testFingerprintIsStableAndValueDependent() {
        let a = ManagedKeyRegistry.fingerprint("sk-managed-abc")
        XCTAssertEqual(a, ManagedKeyRegistry.fingerprint("sk-managed-abc"), "同值必须同指纹")
        XCTAssertNotEqual(a, ManagedKeyRegistry.fingerprint("sk-managed-abd"), "不同值必须不同指纹")
        XCTAssertEqual(a.count, 16)
    }

    /// 指纹不得等于明文——账本 blob 泄露不应等于 Key 泄露。
    func testFingerprintDoesNotLeakTheKey() {
        let secret = "sk-super-secret-value"
        XCTAssertFalse(ManagedKeyRegistry.fingerprint(secret).contains("secret"))
    }

    // MARK: - 免计量绕过（核心回归）

    /// 篡改 UserDefaults 不再能把受管降级成自备。
    func testUserDefaultsTamperingCannotUnmanageAKey() {
        let value = "sk-managed-abc"
        ManagedKeyRegistry.mark(keyName, value: value, managed: true)
        // 攻击者/好奇用户的旧手法：
        UserDefaults.standard.set(false, forKey: "nm_key_managed_\(keyName)")
        UserDefaults.standard.removeObject(forKey: "nm_key_managed_\(keyName)")
        XCTAssertTrue(ManagedKeyRegistry.isManaged(name: keyName, value: value),
                      "受管身份不得由 UserDefaults 决定")
    }

    /// 对预填的**同一个值**点「保存」不得改变计费属性——这是最容易被无意触发的那条。
    func testResavingThePrefilledValueKeepsItManaged() {
        let value = "sk-managed-xyz"
        ManagedKeyRegistry.mark(keyName, value: value, managed: true)
        // 设置页预填了真实 Key，用户一个字不改直接保存：
        XCTAssertTrue(ManagedKeyRegistry.isManaged(name: keyName, value: value))
    }

    /// 换成用户自己的 Key 才算 BYO——这条必须仍然成立，否则 BYO 用户会被误计费。
    func testDifferentValueBecomesUnmanaged() {
        ManagedKeyRegistry.mark(keyName, value: "sk-managed-xyz", managed: true)
        XCTAssertFalse(ManagedKeyRegistry.isManaged(name: keyName, value: "sk-my-own-key"),
                       "用户自备的 Key 不应被计费")
    }

    /// 出厂内置 Key 恒为受管，即使没有任何指纹登记。
    func testBuiltInServiceKeyIsAlwaysManaged() {
        Provisioning.overrideForTesting = ProvisioningPayload(keys: [keyName: "sk-factory"])
        XCTAssertTrue(store.fingerprints.isEmpty)
        XCTAssertTrue(ManagedKeyRegistry.isManaged(name: keyName, value: "sk-factory"))
        XCTAssertFalse(ManagedKeyRegistry.isManaged(name: keyName, value: "sk-not-factory"))
    }

    /// 撤销登记后回到自备。
    func testMarkUnmanagedClearsTheFingerprint() {
        let value = "sk-managed-abc"
        ManagedKeyRegistry.mark(keyName, value: value, managed: true)
        ManagedKeyRegistry.mark(keyName, value: nil, managed: false)
        XCTAssertFalse(ManagedKeyRegistry.isManaged(name: keyName, value: value))
        XCTAssertNil(store.fingerprints[keyName])
    }

    // MARK: - 与计费策略的接线

    /// 端到端语义：受管 → 计量；自备 → 不计量。
    func testMeteringFollowsFingerprintNotDefaults() {
        let value = "sk-managed-abc"
        ManagedKeyRegistry.mark(keyName, value: value, managed: true)
        let managedLookup: (String) -> Bool = { name in
            name == self.keyName && ManagedKeyRegistry.isManaged(name: name, value: value)
        }
        XCTAssertTrue(CreditPolicy.isMetered(stt: .apple, llm: .qwen, managed: managedLookup),
                      "受管 LLM Key 必须计量")

        ManagedKeyRegistry.mark(keyName, value: nil, managed: false)
        XCTAssertFalse(CreditPolicy.isMetered(stt: .apple, llm: .qwen, managed: managedLookup),
                       "自备 Key 不得计量")
    }
}
