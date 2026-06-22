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
    enum TurnKind: String { case cache, live }

    /// Supplies the last-voiced uptime (ns) from the audio path; 0/unknown → use endpoint.
    var voicedClock: (() -> UInt64)?

    private struct Turn { var t0: UInt64; var endpoint: UInt64; var kind: TurnKind?; var first: Double? }
    private var turns: [Int: Turn] = [:]

    // Percentile pools (cold-start excluded), split by source.
    private var firstByKind: [TurnKind: [Double]] = [.cache: [], .live: []]
    private var totalByKind: [TurnKind: [Double]] = [.cache: [], .live: []]
    private var coldDone = false

    func turnStart(_ epoch: Int) {
        let endpoint = DispatchTime.now().uptimeNanoseconds
        var t0 = voicedClock?() ?? 0
        // Fall back to endpoint when there's no audio path (0), a future stamp, or a
        // stale one (>30s) — degrades to the old "T0 = STT final" behavior safely.
        if t0 == 0 || t0 > endpoint || endpoint &- t0 > 30_000_000_000 { t0 = endpoint }
        turns[epoch] = Turn(t0: t0, endpoint: endpoint, kind: nil, first: nil)
    }

    func markFirstReadable(epoch: Int, kind: TurnKind) {
        guard var t = turns[epoch], t.first == nil else { return }
        let first = ms(t.t0, DispatchTime.now().uptimeNanoseconds)
        let endpointDelay = ms(t.t0, t.endpoint)
        t.first = first; t.kind = kind
        turns[epoch] = t
        NSLog("[latency] turn %d (%@) first_readable=%dms (endpoint=%dms + gen=%dms)",
              epoch, kind.rawValue, Int(first), Int(endpointDelay), Int(first - endpointDelay))
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
