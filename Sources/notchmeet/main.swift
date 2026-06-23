import AppKit

#if DEBUG
// Visual-QA only: override the working directory so a bundled debug build (launched via
// `open`, cwd = /) can still find the repo's knowledge/ files. Never used in release.
if let i = CommandLine.arguments.firstIndex(of: "--qa-cwd"),
   CommandLine.arguments.indices.contains(i + 1) {
    FileManager.default.changeCurrentDirectoryPath(CommandLine.arguments[i + 1])
}

// Release-readiness QA: open a Core Audio process tap and report whether the hardened runtime
// (used by the notarized distribution build) still lets it capture audio. Plays nothing — run
// `say …` alongside it. Exits with the result. Never used in a normal run.
if CommandLine.arguments.contains("--audio-selftest") {
    NSLog("SELFTEST: opening audio probe tap under hardened runtime…")
    let cap = AudioCaptureFactory.makeProbe()
    var frames = 0, maxPeak = 0
    cap.onPCM = { data in
        frames += data.count / 2
        data.withUnsafeBytes { raw in
            for v in raw.bindMemory(to: Int16.self) { let a = abs(Int(v)); if a > maxPeak { maxPeak = a } }
        }
    }
    do {
        try cap.start()
        NSLog("SELFTEST: tap START OK — hardened runtime did NOT block tap creation")
    } catch {
        NSLog("SELFTEST: tap START FAILED: %@", String(describing: error))
        cap.stop(); exit(2)
    }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 6))
    cap.stop()
    let verdict = maxPeak > 300 ? "AUDIO CAPTURED ✓ (hardened runtime + entitlement OK)"
                                : "silence — no audio played, or permission not granted"
    NSLog("SELFTEST: frames=%d maxPeak=%d → %@", frames, maxPeak, verdict)
    exit(maxPeak > 300 ? 0 : 3)
}
#endif

// Accessory app: no Dock icon, lives at the notch like a menu-bar app.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
