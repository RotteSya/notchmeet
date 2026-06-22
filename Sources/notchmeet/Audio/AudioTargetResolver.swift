import AppKit
import CoreAudio

/// Resolves WHICH running app's audio the tap should capture, so notchmeet records only the
/// call app's output — not all system audio. This is the data-minimization half of the
/// privacy fix: the page promises "only the interviewer", so we capture exactly one app.
///
/// Precedence: the user's explicit pick (Settings) → the frontmost known call app → any
/// running native conferencing app → the frontmost/only browser. If nothing matches we
/// return `nil` and the caller surfaces a "open your call app" prompt — we never silently
/// fall back to a global tap.
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

    /// Resolve the capture target, or `nil` when no suitable app is running.
    static func resolve() -> Resolution? {
        let running = NSWorkspace.shared.runningApplications

        // 1. Explicit user pick wins — but only if that app is actually running.
        if let pick = Settings.captureTargetBundleID {
            let apps = running.filter { $0.bundleIdentifier == pick }
            let ids = apps.compactMap { processObject(forPID: $0.processIdentifier) }
            if !ids.isEmpty { return Resolution(ids: ids, label: apps.first?.localizedName ?? pick) }
            return nil
        }

        // 2. Auto: the frontmost app, if it's a known call app (you start recording while
        //    looking at the call). Strongest signal.
        if let front = NSWorkspace.shared.frontmostApplication,
           let bid = front.bundleIdentifier, knownCallApps.contains(bid),
           let id = processObject(forPID: front.processIdentifier) {
            return Resolution(ids: [id], label: front.localizedName ?? bid)
        }

        // 3. Auto: any running NATIVE conferencing app(s).
        let natives = running.filter { nativeCallApps.contains($0.bundleIdentifier ?? "") }
        let nativeIDs = natives.compactMap { processObject(forPID: $0.processIdentifier) }
        if !nativeIDs.isEmpty {
            let label = natives.compactMap { $0.localizedName }.joined(separator: ", ")
            return Resolution(ids: nativeIDs, label: label)
        }

        // 4. Auto: a browser (web call) — prefer the frontmost, else the first running.
        let browsers = running.filter { browserApps.contains($0.bundleIdentifier ?? "") }
        let chosen = browsers.first { $0 == NSWorkspace.shared.frontmostApplication } ?? browsers.first
        if let b = chosen, let id = processObject(forPID: b.processIdentifier) {
            return Resolution(ids: [id], label: b.localizedName ?? (b.bundleIdentifier ?? ""))
        }

        return nil
    }

    /// Translate a BSD process id to its Core Audio process object id (macOS 14.4+),
    /// which is what `CATapDescription(stereoMixdownOfProcesses:)` expects.
    static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var pidVar = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let err = withUnsafeMutablePointer(to: &pidVar) { ptr -> OSStatus in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<pid_t>.size), ptr, &size, &objectID)
        }
        return (err == noErr && objectID != kAudioObjectUnknown) ? objectID : nil
    }
}
