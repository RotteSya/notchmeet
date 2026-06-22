import AppKit
import CoreAudio
import Darwin

/// Resolves WHICH running app's audio the tap should capture, so notchmeet records only the
/// call app's output — not all system audio. This is the data-minimization half of the
/// privacy fix: the page promises "only the interviewer", so we capture exactly one app.
///
/// Precedence: the user's explicit pick (Settings) → the frontmost known call app → any
/// running native conferencing app → the frontmost/only browser. If nothing matches we
/// return `nil` and the caller surfaces a "open your call app" prompt — we never silently
/// fall back to a global tap.
///
/// IMPORTANT (multi-process apps): a browser/Electron call renders audio in a CHILD process,
/// never the main window process. Chrome routes every tab's audio through a `Google Chrome
/// Helper` (audio-service) child; the main process does no audio IO. So we must tap EVERY
/// audio process object in the target app's process tree (main + children), not just the
/// main PID — tapping only the main PID captures pure silence (the bug this fixes).
@available(macOS 14.4, *)
enum AudioTargetResolver {
    /// Native conferencing apps — preferred when running, since a browser is often open for
    /// unrelated reasons. (A web call inside a browser is handled by `browserApps`.)
    static let nativeCallApps: [String] = [
        "us.zoom.xos",                  // Zoom
        "com.microsoft.teams",          // Teams (classic)
        "com.microsoft.teams2",         // Teams (new)
        "Cisco-Systems.Spark",          // Webex
        "com.cisco.webexmeetingsapp",   // Webex Meetings
        "com.apple.FaceTime",           // FaceTime
        "com.hnc.Discord",              // Discord
        "com.skype.skype",              // Skype
        "com.google.meetings",          // Google Meet (standalone)
    ]
    /// Browsers — Meet/Teams-web run here. NOTE: a tap on a browser captures the WHOLE
    /// browser (every tab); a single tab can't be isolated. The UI discloses this.
    static let browserApps: [String] = [
        "com.google.Chrome",
        "com.apple.Safari",
        "company.thebrowser.Browser",   // Arc
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.brave.Browser",
    ]
    static var knownCallApps: [String] { nativeCallApps + browserApps }

    struct Resolution { let ids: [AudioObjectID]; let label: String }

    /// Resolve the capture target, or `nil` when no suitable app is running / has no audio.
    static func resolve() -> Resolution? {
        guard let (apps, label) = targetApps() else { return nil }
        let ids = audioObjects(ofApps: apps)
        guard !ids.isEmpty else {
            // The app is running but no process in its tree has done audio IO yet (e.g. a
            // muted/just-opened call). Nothing to tap → caller prompts to open the call.
            NSLog("[audio] target '%@' has no audio process objects yet", label)
            return nil
        }
        return Resolution(ids: ids, label: label)
    }

    /// Pick the target app(s) by precedence (unchanged behavior). Returns the running apps to
    /// capture plus a human label, or `nil` when nothing suitable is running.
    private static func targetApps() -> ([NSRunningApplication], String)? {
        let running = NSWorkspace.shared.runningApplications

        // 1. Explicit user pick wins — but only if that app is actually running.
        if let pick = Settings.captureTargetBundleID {
            let apps = running.filter { $0.bundleIdentifier == pick }
            guard !apps.isEmpty else { return nil }
            return (apps, apps.first?.localizedName ?? pick)
        }

        // 2. The frontmost app, if it's a known call app (you start recording while looking
        //    at the call). Strongest signal.
        if let front = NSWorkspace.shared.frontmostApplication,
           let bid = front.bundleIdentifier, knownCallApps.contains(bid) {
            return ([front], front.localizedName ?? bid)
        }

        // 3. Any running NATIVE conferencing app(s).
        let natives = running.filter { nativeCallApps.contains($0.bundleIdentifier ?? "") }
        if !natives.isEmpty {
            return (natives, natives.compactMap { $0.localizedName }.joined(separator: ", "))
        }

        // 4. A browser (web call) — prefer the frontmost, else the first running.
        let browsers = running.filter { browserApps.contains($0.bundleIdentifier ?? "") }
        let chosen = browsers.first { $0 == NSWorkspace.shared.frontmostApplication } ?? browsers.first
        if let b = chosen {
            return ([b], b.localizedName ?? (b.bundleIdentifier ?? ""))
        }

        return nil
    }

    /// Every Core Audio process object whose process IS one of `apps` or a descendant of one
    /// (helpers are children of the app's main process). We enumerate the live object list
    /// rather than translating each PID, because only processes that have actually done audio
    /// IO own a process object — and for a browser that's the audio-service helper child, not
    /// the main window process. Capturing the whole tree keeps the "only this app" promise.
    private static func audioObjects(ofApps apps: [NSRunningApplication]) -> [AudioObjectID] {
        let appPIDs = Set(apps.map { $0.processIdentifier })
        var matched: [AudioObjectID] = []
        for obj in processObjectList() {
            let p = pid(ofProcessObject: obj)
            guard p > 0, belongs(pid: p, toAppPIDs: appPIDs) else { continue }
            matched.append(obj)
        }
        if !matched.isEmpty {
            NSLog("[audio] tapping %d process(es) for target (pids: %@)", matched.count,
                  matched.map { String(pid(ofProcessObject: $0)) }.joined(separator: ","))
        }
        return matched
    }

    /// True if `pid` is one of `appPIDs` or descends from one (walks the parent chain, so a
    /// helper at any nesting depth under the call app counts). Robust to Chrome's code-sign
    /// "clone" main process, whose executable path differs from its helpers'.
    private static func belongs(pid: pid_t, toAppPIDs appPIDs: Set<pid_t>) -> Bool {
        var cur = pid, hops = 0
        while cur > 1, hops < 64 {
            if appPIDs.contains(cur) { return true }
            cur = parentPID(of: cur)
            hops += 1
        }
        return false
    }

    /// All audio process objects known to the HAL (processes that have done audio IO).
    private static func processObjectList() -> [AudioObjectID] {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &objs) == noErr else { return [] }
        return objs
    }

    /// The BSD pid behind an audio process object (macOS 14.4+), or -1.
    private static func pid(ofProcessObject obj: AudioObjectID) -> pid_t {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &pid) == noErr else { return -1 }
        return pid
    }

    /// Parent pid of `pid` via libproc, or -1. Used to group an app's helper children.
    private static func parentPID(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        return n == size ? pid_t(info.pbi_ppid) : -1
    }
}
