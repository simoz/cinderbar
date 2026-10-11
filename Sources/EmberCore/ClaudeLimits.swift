import Foundation

/// Claude's plan meter. Claude Code leaves no quota in its transcripts, so this
/// asks the same endpoint Claude Code's own `/usage` uses, with the sign-in
/// Claude Code already keeps in the login keychain. The token is read with
/// `/usr/bin/security` (which Claude Code itself uses, so its keychain item
/// trusts it), sent only to api.anthropic.com, never stored or logged, and
/// never refreshed: refreshing would rotate Claude Code's own sign-in.
///
/// The endpoint is undocumented; every field is read defensively and anything
/// that does not parse is withheld rather than shown as 0%.
public enum ClaudeLimits {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public static func fetch(now: Double = Date().timeIntervalSince1970 * 1000) async -> AgentLimits {
        let token: String
        switch readToken(now: now) {
        case .success(let t): token = t
        case .failure(let e): return AgentLimits(status: e.message)
        }
        var req = URLRequest(url: endpoint, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { return AgentLimits(status: "Sign-in rejected: run `claude` in a terminal to sign in again") }
            guard code == 200 else { return AgentLimits(status: "Usage service answered \(code)") }
            return parse(data, measuredMs: Date().timeIntervalSince1970 * 1000)
        } catch {
            return AgentLimits(status: "Usage service unreachable")
        }
    }

    public static func parse(_ data: Data, measuredMs: Double) -> AgentLimits {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return AgentLimits(status: "Usage reply not understood")
        }
        let known: [(key: String, name: String, kind: LimitKind, span: Double)] = [
            ("five_hour", "5-hour", .session, 5 * hourMs),
            ("seven_day", "Weekly", .plan, weekMs),
            ("seven_day_opus", "Weekly Opus", .extra, weekMs),
            ("seven_day_sonnet", "Weekly Sonnet", .extra, weekMs),
        ]
        var windows: [LimitReading] = []
        for k in known {
            guard let w = obj[k.key] as? [String: Any] else { continue }
            let pct = double(w["utilization"]).map { $0 / 100 }
            let resets = parseTimestamp(w["resets_at"])
            // An extra window with nothing in it is noise, not a limit.
            if k.kind == .extra && (pct ?? 0) == 0 && resets == nil { continue }
            windows.append(LimitReading(name: k.name, kind: k.kind, percent: pct, resetsMs: resets,
                                        windowMs: k.span, measuredMs: measuredMs))
        }
        if windows.isEmpty { return AgentLimits(status: "No limits in the usage reply") }
        return AgentLimits(windows: windows)
    }

    struct TokenError: Error { let message: String }

    static func readToken(now: Double) -> Result<String, TokenError> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return .failure(TokenError(message: "Keychain not readable")) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return .failure(TokenError(message: "Not signed in to Claude Code")) }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return .failure(TokenError(message: "Claude Code sign-in not understood"))
        }
        if let exp = double(oauth["expiresAt"]), exp > 0, exp < now {
            return .failure(TokenError(message: "Keychain sign-in expired: run `claude` in a terminal to refresh it"))
        }
        return .success(token)
    }
}
