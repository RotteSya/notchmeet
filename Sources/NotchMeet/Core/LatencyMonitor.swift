import Foundation

/// Measures the §4 SLA faithfully.
///  - **T0** ≈ the interviewer's last phoneme, taken from the audio path's last-voiced
///    timestamp (`voicedClock`) — NOT "STT final received". The gap `T_endpoint − T0`
///    is the endpointing delay and is part of the budget, so it must be inside the SLA.
///  - **T1** = first complete, directly speakable sentence committed; turn end = total.
///  - Reports first-readable & total measured from T0, plus the endpoint delay, with
///    p50/p95/p99 split by CACHE vs LIVE. The first completed turn is reported
///    separately as cold-start (first WS connect + first LLM call) and excluded from
///    the percentiles.
///
/// Caveat: the global tap's last-voiced is a real-time VAD proxy; sustained background
/// noise keeps it near "now", shrinking the measured endpoint delay. Cleanest with a
/// per-process tap (S1 refinement) or offline waveform ground-truth.
final class LatencyMonitor {
    /// `fact` = 本机确定性事实即答（不走网络，几乎 0ms）。单列一档而不是并进 cache：
    /// 混进去会把缓存命中的 p50/p95 分布整体拉平，之后再也看不出路由到底快不快。
    enum TurnKind: String { case cache, live, fact }

    /// Supplies the last-voiced uptime (ns) from the audio path; 0/unknown → use endpoint.
    var voicedClock: (() -> UInt64)?

    /// 每轮的 STT 交付耗时（ms，最后一个音素 → 最后终稿到达），turnStart 时上报。
    /// 供审计 R1 的慢终稿探测（SttHealthTracker → 热切换端侧引擎）。0（无音频路径 /
    /// 时间戳失真而退化）不上报——探测器只该吃真实测量值。
    var onSttFinalDelay: ((Double) -> Void)?

    private struct Turn {
        var t0: UInt64
        var endpoint: UInt64
        /// 最后一个终稿到达的时刻。把 `endpoint − t0` 这段一分为二：
        /// `sttFinal − t0` 是 STT 的交付耗时（别人慢），
        /// `endpoint − sttFinal` 是我们的 settle 等待（自己慢）。
        /// 混在一起时，一次 4.5s 的端点延迟无法判断该去调窗口还是该查网络。
        var sttFinal: UInt64
        var kind: TurnKind?
        var first: Double?
        /// Wall time of `markFirstReadable`, so `restamp` can recompute `first`
        /// after speculative T0 is replaced by the real last-phoneme.
        var firstMarkNs: UInt64?
        var speculative: Bool
    }
    private var turns: [Int: Turn] = [:]

    // Percentile pools (cold-start excluded), split by source.
    private var firstByKind: [TurnKind: [Double]] = [.cache: [], .live: []]
    private var totalByKind: [TurnKind: [Double]] = [.cache: [], .live: []]
    private var coldDone = false

    /// - Parameter sttFinalNs: 最后一个终稿到达的 uptime；0 = 未知（退化为不拆分）。
    /// - Parameter speculative: 投机开轮时人还在说话，voicedClock / lastFinal 都是
    ///   上一轮或「此刻仍在发声」的噪声。不算进 R1 慢终稿，等 `restamp` 用真终稿重盖。
    func turnStart(_ epoch: Int, sttFinalNs: UInt64 = 0, speculative: Bool = false) {
        let clock = stamp(sttFinalNs: sttFinalNs)
        turns[epoch] = Turn(t0: clock.t0, endpoint: clock.endpoint, sttFinal: clock.final,
                            kind: nil, first: nil, firstMarkNs: nil, speculative: speculative)
        guard !speculative else { return }
        let sttLag = ms(clock.t0, clock.final)
        if sttLag > 0 { onSttFinalDelay?(sttLag) }
    }

    /// Settle 确认投机问句之后：用真正的最后音素 / 本轮终稿重盖 T0。
    /// 已经记过的 first_readable 按新 T0 重算（答案比话音更早出来时钳到 0）。
    func restamp(_ epoch: Int, sttFinalNs: UInt64) {
        guard var t = turns[epoch] else { return }
        let clock = stamp(sttFinalNs: sttFinalNs)
        t.t0 = clock.t0
        t.endpoint = clock.endpoint
        t.sttFinal = clock.final
        t.speculative = false
        if let mark = t.firstMarkNs {
            t.first = mark >= clock.t0 ? ms(clock.t0, mark) : 0
        }
        turns[epoch] = t
        let sttLag = ms(clock.t0, clock.final)
        if sttLag > 0 { onSttFinalDelay?(sttLag) }
    }

    private func stamp(sttFinalNs: UInt64) -> (t0: UInt64, endpoint: UInt64, final: UInt64) {
        let endpoint = DispatchTime.now().uptimeNanoseconds
        var t0 = voicedClock?() ?? 0
        // Fall back to endpoint when there's no audio path (0), a future stamp, or a
        // stale one (>30s) — degrades to the old "T0 = STT final" behavior safely.
        if t0 == 0 || t0 > endpoint || endpoint &- t0 > 30_000_000_000 { t0 = endpoint }
        // 钳进 [t0, endpoint]：终稿早于最后一个音素（VAD 比 STT 端点器更敏感时可能
        // 发生）或晚于提交都不是有意义的拆分点，此时把整段算作 STT 交付。
        let final = (sttFinalNs >= t0 && sttFinalNs <= endpoint) ? sttFinalNs : endpoint
        return (t0, endpoint, final)
    }

    func markFirstReadable(epoch: Int, kind: TurnKind) {
        guard var t = turns[epoch], t.first == nil else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let first = now >= t.t0 ? ms(t.t0, now) : 0
        let endpointDelay = ms(t.t0, t.endpoint)
        let sttLag = ms(t.t0, t.sttFinal)          // 等 STT 交付终稿（外部）
        let settleWait = ms(t.sttFinal, t.endpoint) // 我们自己的 settle 等待（可调）
        t.first = first; t.kind = kind; t.firstMarkNs = now
        turns[epoch] = t
        NSLog("[latency] turn %d (%@) first_readable=%dms (stt=%dms + settle=%dms + gen=%dms)%@",
              epoch, kind.rawValue, Int(first),
              Int(sttLag), Int(settleWait), Int(first - endpointDelay),
              t.speculative ? " spec" : "")
    }

    func turnEnd(_ epoch: Int) {
        guard let t = turns[epoch] else { return }
        turns[epoch] = nil
        let total = ms(t.t0, DispatchTime.now().uptimeNanoseconds)
        let kind = t.kind ?? .live
        let first = t.first ?? -1

        if !coldDone {
            coldDone = true
            NSLog("[latency] turn %d COLD-START (%@) first=%dms total=%dms — excluded from percentiles",
                  epoch, kind.rawValue, Int(first), Int(total))
            return
        }
        if first >= 0 { firstByKind[kind, default: []].append(first) }
        totalByKind[kind, default: []].append(total)

        let f = firstByKind[kind] ?? []
        let tot = totalByKind[kind] ?? []
        NSLog("[latency] turn %d (%@) total=%dms first=%dms | %@ n=%d  first p50/p95/p99=%d/%d/%d  total p95=%dms",
              epoch, kind.rawValue, Int(total), Int(first), kind.rawValue, f.count,
              Int(pct(f, 0.50)), Int(pct(f, 0.95)), Int(pct(f, 0.99)), Int(pct(tot, 0.95)))
    }

    private func ms(_ a: UInt64, _ b: UInt64) -> Double { Double(b &- a) / 1_000_000 }

    private func pct(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return -1 }
        let s = xs.sorted()
        let idx = min(s.count - 1, Int((Double(s.count) * p).rounded(.down)))
        return s[idx]
    }
}
