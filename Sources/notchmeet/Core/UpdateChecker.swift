import Foundation

/// Checks GitHub Releases for a newer notchmeet build. The app ships as a notarized `.dmg`
/// published at github.com/RotteSya/notchmeet/releases (tagged `v<version>`, see
/// scripts/release.sh), so "check for updates" just compares the latest published release
/// against this bundle's version. Self-contained: no external dependency, no telemetry —
/// one unauthenticated GitHub API call, only when the user presses the button.
enum UpdateChecker {
    /// owner/repo that publishes the releases (matches the git remote + scripts/release.sh).
    static let repo = "RotteSya/notchmeet"

    struct Release {
        let version: String   // normalized numeric, e.g. "1.0.2"
        let page: URL         // the release page (html_url) — shows notes + the .dmg asset
    }

    enum Outcome {
        case upToDate
        case updateAvailable(Release)
    }

    enum CheckError: Error, LocalizedError {
        case badURL
        case http(Int)
        case malformedResponse
        var errorDescription: String? {
            switch self {
            case .badURL: return "bad URL"
            case .http(let code): return "HTTP \(code)"
            case .malformedResponse: return "malformed response"
            }
        }
    }

    /// This bundle's marketing version (CFBundleShortVersionString); "0" in unbundled dev runs.
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Query the latest published release and decide whether it is newer than this build.
    static func check() async throws -> Outcome {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw CheckError.badURL
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("notchmeet", forHTTPHeaderField: "User-Agent") // GitHub rejects UA-less calls
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15

        let (data, resp) = try await URLSession.shared.data(for: request)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CheckError.http(http.statusCode)
        }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let pageString = obj["html_url"] as? String,
              let page = URL(string: pageString) else {
            throw CheckError.malformedResponse
        }

        let latest = normalized(tag)
        if isNewer(latest, than: normalized(currentVersion)) {
            return .updateAvailable(Release(version: latest, page: page))
        }
        return .upToDate
    }

    /// Strip a leading `v` and surrounding whitespace ("v1.0.2" → "1.0.2").
    static func normalized(_ version: String) -> String {
        var v = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.first == "v" || v.first == "V" { v.removeFirst() }
        return v
    }

    /// Numeric dotted-version compare so 1.0.10 > 1.0.9 (a lexical compare gets this wrong).
    /// Missing or non-numeric segments count as 0.
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
