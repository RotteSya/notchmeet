import Foundation

/// Fires `onTimeout` after `timeout` elapses with no `noteActivity()` call. Here
/// "activity" = the interviewer was heard speaking (an STT transcript arrived), so a
/// timeout means the interviewer has been silent for the whole window → auto-pause.
///
/// `noteActivity()` may be called from the STT provider's network thread; it only
/// stamps a timestamp under a short-held lock. A coarse main-thread timer does the
/// elapsed check, so we never reschedule a timer per transcript.
final class InactivityMonitor {
    /// No-speech duration that triggers a timeout. 5 minutes by default (per request);
    /// override with `FI_IDLE_PAUSE_SECS` for testing.
    private let timeout: TimeInterval
    /// Fired once on the main thread when no activity has occurred for `timeout`.
    /// Monitoring stops after firing; call `start()` again to re-arm.
    var onTimeout: (() -> Void)?

    /// Resolved timeout in seconds (reflects any `FI_IDLE_PAUSE_SECS` override).
    var seconds: TimeInterval { timeout }

    private let lock = NSLock()
    private var lastActivityNs: UInt64 = 0
    private var timer: Timer?

    init(timeout: TimeInterval? = nil) {
        if let timeout {
            self.timeout = timeout
        } else if let s = ProcessInfo.processInfo.environment["FI_IDLE_PAUSE_SECS"],
                  let v = TimeInterval(s), v > 0 {
            self.timeout = v
        } else {
            self.timeout = 300
        }
    }

    /// Begin (or restart) monitoring. Resets the inactivity clock to now. Call on main.
    func start() {
        stop()
        stampNow()
        // Coarse polling — a multi-minute timeout needs no fine resolution.
        let interval = max(1.0, min(15.0, timeout / 4))
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = interval / 3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Stop monitoring (also called internally after a one-shot timeout). Call on main.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Mark that the interviewer was just heard. Safe to call from any thread.
    func noteActivity() {
        stampNow()
    }

    private func stampNow() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock(); lastActivityNs = now; lock.unlock()
    }

    private func tick() {
        lock.lock(); let last = lastActivityNs; lock.unlock()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- last) / 1_000_000_000
        guard elapsed >= timeout else { return }
        stop()              // one-shot; owner re-arms via start() on resume
        onTimeout?()
    }
}
