import Foundation

struct CLIInfo {
    var installed: Bool
    var path: String?
    var version: String?
}

enum CliError: Error, LocalizedError {
    case notFound(String)
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .notFound(let c): return "\(c) not found"
        case .failed(let e): return "CLI failed: \(String(e.suffix(300)))"
        }
    }
}

/// Thread-safe holder so onCancel (arbitrary thread) can reach the running Process.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var proc: Process?
    func set(_ p: Process) { lock.lock(); proc = p; lock.unlock() }
    func terminate() { lock.lock(); let p = proc; lock.unlock(); p?.terminate() }
    var isRunning: Bool { lock.lock(); let p = proc; lock.unlock(); return p?.isRunning ?? false }
}

/// 增量收集子进程 stdout/stderr。readabilityHandler 在各自的线程上回调，
/// 所以累积必须加锁。
private final class OutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func appendOut(_ d: Data) {
        guard !d.isEmpty else { return }
        lock.lock(); out.append(d); lock.unlock()
    }

    func appendErr(_ d: Data) {
        guard !d.isEmpty else { return }
        lock.lock(); err.append(d); lock.unlock()
    }

    func strings() -> (out: String, err: String) {
        lock.lock(); defer { lock.unlock() }
        return (String(data: out, encoding: .utf8) ?? "",
                String(data: err, encoding: .utf8) ?? "")
    }
}

/// Detects + runs local agent CLIs (claude / codex) for OFFLINE pre-generation only
/// (never on the realtime path — PLAN §5). General text interface (no image binding),
/// per-call isolated temp dir, real cancellation via the surrounding Task.
/// Detection logic ported from NotchTutor's CLIRunner; run() is rewritten generic.
enum CliRunner {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    /// 单次调用的墙钟上限。CLI 可能因等待登录/网络而永远不返回，
    /// 而 runPrep 的调用方会一直显示「正在预生成回答…」。
    static let timeout: TimeInterval = 120
    private static let timeoutQueue = DispatchQueue(label: "com.notchmeet.cli.timeout")

    static func candidateDirs() -> [String] {
        var dirs = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/local/sbin", "/usr/bin", "/bin",
            "\(home)/.local/bin", "\(home)/.npm-global/bin",
            "\(home)/.cargo/bin", "\(home)/.bun/bin", "\(home)/.deno/bin",
            "\(home)/.volta/bin", "\(home)/.asdf/shims",
            "/Applications/Codex.app/Contents/Resources",
            "\(home)/.claude/local",
        ]
        let nvm = "\(home)/.nvm/versions/node"
        if let vers = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            for v in vers { dirs.append("\(nvm)/\(v)/bin") }
        }
        return dirs
    }

    static func augmentedEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = candidateDirs().joined(separator: ":") + ":" + (env["PATH"] ?? "")
        return env
    }

    private static func findInDirs(_ bin: String) -> String? {
        let fm = FileManager.default
        for d in candidateDirs() {
            let p = "\(d)/\(bin)"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func detect() -> [String: CLIInfo] {
        var out: [String: CLIInfo] = [:]
        for bin in ["claude", "codex"] {
            if let p = findInDirs(bin) {
                out[bin] = CLIInfo(installed: true, path: p, version: nil)
            } else {
                out[bin] = CLIInfo(installed: false, path: nil, version: nil)
            }
        }
        return out
    }

    /// Per-call isolated empty dir so the agent CLIs don't crawl the project.
    private static func workDir() -> String {
        let dir = NSTemporaryDirectory() + "fi-prep-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Run the CLI once with a text prompt, return full stdout. Read-only/no-tools.
    static func run(cli: String, binPath: String, prompt: String) async throws -> String {
        let args: [String]
        if cli == "claude" {
            args = ["-p", prompt, "--output-format", "text",
                    "--permission-mode", "dontAsk",
                    "--disallowedTools", "Edit,Write,Bash,WebFetch,WebSearch"]
        } else {
            args = ["exec", "--sandbox", "read-only", "--skip-git-repo-check", prompt]
        }
        let wd = workDir()
        defer { try? FileManager.default.removeItem(atPath: wd) }

        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: binPath)
                p.arguments = args
                p.environment = augmentedEnv()
                p.currentDirectoryURL = URL(fileURLWithPath: wd)
                box.set(p)
                let o = Pipe(); let e = Pipe()
                p.standardOutput = o; p.standardError = e
                p.standardInput = FileHandle.nullDevice

                // 增量读取。旧实现只在 terminationHandler 里 readDataToEndOfFile：
                // CLI 输出一旦超过管道缓冲（64KB）写端就阻塞，子进程永不退出，
                // terminationHandler 永不触发 —— 双向死锁，刘海永远停在「正在预生成」。
                let sink = OutputSink()
                o.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty { h.readabilityHandler = nil } else { sink.appendOut(d) }
                }
                e.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty { h.readabilityHandler = nil } else { sink.appendErr(d) }
                }

                p.terminationHandler = { proc in
                    o.fileHandleForReading.readabilityHandler = nil
                    e.fileHandleForReading.readabilityHandler = nil
                    // 收尾：取走管道里可能残留的最后一段。
                    sink.appendOut(o.fileHandleForReading.availableData)
                    sink.appendErr(e.fileHandleForReading.availableData)
                    let (out, err) = sink.strings()
                    if proc.terminationStatus == 0 {
                        cont.resume(returning: out.trimmingCharacters(in: .whitespacesAndNewlines))
                    } else {
                        cont.resume(throwing: CliError.failed(err))
                    }
                }
                do { try p.run() } catch { cont.resume(throwing: error); return }

                // 超时兜底：CLI 卡住（等待登录/网络）时不能让调用方无限期挂起。
                timeoutQueue.asyncAfter(deadline: .now() + timeout) { [weak box] in
                    guard let box, box.isRunning else { return }
                    NSLog("[cli] %@ exceeded %.0fs — terminating", cli, timeout)
                    box.terminate()
                }
            }
        } onCancel: {
            box.terminate()   // termination fires the handler → continuation resumes with .failed
        }
    }
}
