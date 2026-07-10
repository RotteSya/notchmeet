#!/usr/bin/env swift
// 开发者侧商业化工具（App 本体永不包含私钥）：
//   swift scripts/nmtool.swift gen-keys
//       生成 Ed25519 签名密钥对 → 私钥存 ~/.notchmeet/credit-signing.key，打印公钥。
//   swift scripts/nmtool.swift mint --minutes 120 [--id C-001] [--exp 2027-12-31] [--keys keys.json] [--count 5]
//       铸造充值码（nmc1.…）。--keys 让码同时携带服务 Key（给公开构建用户激活）。
//   swift scripts/nmtool.swift provision --keys keys.json [--buy URL] [--gift 3600]
//       生成出厂受管服务配置 → ~/.notchmeet/provisioning.nmp（release.sh 自动打进 .app）。
//   swift scripts/nmtool.swift decode <nmc1.…|nmp1.…|nmk1.…>
//       调试：解出负载明文。
//
// keys.json 形如: {"DASHSCOPE_API_KEY":"sk-…","DEEPGRAM_API_KEY":"…"}
// 编解码格式必须与 App 内 Provisioning.swift / CreditCode.swift / SetupCode.swift 一致。

import CryptoKit
import Foundation

// 尊重 $HOME（homeDirectoryForCurrentUser 会无视它）：既是 Unix 惯例，也让测试可用沙箱 HOME。
let home = ProcessInfo.processInfo.environment["HOME"].map(URL.init(fileURLWithPath:))
    ?? FileManager.default.homeDirectoryForCurrentUser
let vaultDir = home.appendingPathComponent(".notchmeet")
let keyFile = vaultDir.appendingPathComponent("credit-signing.key")
let nmpFile = vaultDir.appendingPathComponent("provisioning.nmp")
let xorKey = Array("nm-provision-v1".utf8)   // = Provisioning.xorKey

func b64url(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
func unb64url(_ s: String) -> Data? {
    var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while b64.count % 4 != 0 { b64 += "=" }
    return Data(base64Encoded: b64)
}
func xor(_ data: Data) -> Data {
    Data(data.enumerated().map { i, b in b ^ xorKey[i % xorKey.count] })
}
func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("ERROR: " + msg + "\n").utf8))
    exit(1)
}
func arg(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: "--" + name),
          CommandLine.arguments.indices.contains(i + 1) else { return nil }
    return CommandLine.arguments[i + 1]
}

func loadPrivateKey() -> Curve25519.Signing.PrivateKey {
    guard let b64 = try? String(contentsOf: keyFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
          let raw = Data(base64Encoded: b64),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("no signing key at \(keyFile.path) — run `gen-keys` first")
    }
    return key
}

func loadKeysJSON(_ path: String) -> [String: String] {
    guard let data = FileManager.default.contents(atPath: path),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String], !obj.isEmpty else {
        fail("cannot read keys JSON at \(path)")
    }
    return obj
}

let cmd = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
switch cmd {
case "gen-keys":
    if FileManager.default.fileExists(atPath: keyFile.path) {
        let key = loadPrivateKey()
        print("EXISTS  \(keyFile.path)")
        print("public: \(key.publicKey.rawRepresentation.base64EncodedString())")
        exit(0)
    }
    try? FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
    let key = Curve25519.Signing.PrivateKey()
    try key.rawRepresentation.base64EncodedString().write(to: keyFile, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
    print("created \(keyFile.path)  (chmod 600 — back it up; losing it invalidates all future minting)")
    print("public: \(key.publicKey.rawRepresentation.base64EncodedString())")

case "mint":
    guard let minStr = arg("minutes"), let minutes = Int(minStr), minutes > 0 else {
        fail("--minutes N is required")
    }
    let key = loadPrivateKey()
    let keysDict: [String: String]? = arg("keys").map(loadKeysJSON)
    let exp = arg("exp")
    let count = arg("count").flatMap(Int.init) ?? 1
    for i in 0..<count {
        let id = arg("id").map { count > 1 ? "\($0)-\(i + 1)" : $0 }
            ?? "C-" + UUID().uuidString.prefix(8).uppercased()
        var payload: [String: Any] = ["id": id, "min": minutes]
        if let keysDict { payload["keys"] = keysDict }
        if let exp { payload["exp"] = exp }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let sig = try key.signature(for: data)
        print("nmc1.\(b64url(data)).\(b64url(sig))")
    }

case "provision":
    guard let keysPath = arg("keys") else { fail("--keys keys.json is required") }
    let key = loadPrivateKey()
    var payload: [String: Any] = [
        "keys": loadKeysJSON(keysPath),
        "pub": key.publicKey.rawRepresentation.base64EncodedString(),
    ]
    if let buy = arg("buy") { payload["buy"] = buy }
    if let gift = arg("gift").flatMap(Int.init) { payload["gift"] = gift }
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let content = "nmp1." + b64url(xor(data))
    try? FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
    try content.write(to: nmpFile, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: nmpFile.path)
    print("wrote \(nmpFile.path) — release.sh bundles it into the .app automatically")

case "decode":
    guard CommandLine.arguments.count > 2 else { fail("decode <code>") }
    let raw = CommandLine.arguments[2].trimmingCharacters(in: .whitespacesAndNewlines)
    let plain: Data?
    if raw.hasPrefix("nmp1.") {
        plain = unb64url(String(raw.dropFirst(5))).map(xor)
    } else if raw.hasPrefix("nmc1.") {
        let parts = raw.dropFirst(5).split(separator: ".", maxSplits: 1)
        plain = parts.first.flatMap { unb64url(String($0)) }
    } else if raw.hasPrefix("nmk1.") {
        plain = unb64url(String(raw.dropFirst(5)))
    } else {
        plain = nil
    }
    guard let plain, let s = String(data: plain, encoding: .utf8) else { fail("cannot decode") }
    print(s)

default:
    print("""
    usage: swift scripts/nmtool.swift <command>
      gen-keys                         create the Ed25519 signing keypair
      mint --minutes N [--id X] [--exp yyyy-MM-dd] [--keys keys.json] [--count N]
      provision --keys keys.json [--buy URL] [--gift seconds]
      decode <nmc1.…|nmp1.…|nmk1.…>
    """)
}
