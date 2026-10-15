import Foundation

// Kimi (Kimi Code). Ported from Burn Bar's collector:
//
//   ~/.claude/projects/**/*.jsonl  Kimi Code speaks the Anthropic API, so run
//                                  through Claude Code its turns land in Claude's
//                                  transcripts. Only the model id (kimi-*,
//                                  moonshot-*) tells them apart; without the split
//                                  Kimi's spend would be billed to Claude's lane.
//   GET <base>/usages              the quota: a request window that cuts you off
//                                  and monthly credit ratios. (/usage is a 404.)
//   GET <base>/me                  the plan tier and the key owner's email.
//
// The key comes from KIMI_API_KEY in the environment, else ~/.env. It is sent
// only to the Kimi base URL, never stored, logged or printed.

public enum Kimi {
    public static let defaultBase = "https://api.kimi.com/coding/v1"

    public static func isKimiModel(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.hasPrefix("kimi") || m.hasPrefix("moonshot")
    }

    /// KIMI_API_KEY from the environment, else from a `KIMI_API_KEY=` line in
    /// ~/.env (an app started from Finder has no shell environment).
    public static func apiKey(env: [String: String] = ProcessInfo.processInfo.environment,
                              dotenv: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".env")) -> String? {
        if let k = env["KIMI_API_KEY"]?.trimmingCharacters(in: .whitespaces), !k.isEmpty { return k }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: dotenv.path),
              let size = (attrs[.size] as? NSNumber)?.intValue, size <= 1 << 20,
              let text = try? String(contentsOf: dotenv, encoding: .utf8) else { return nil }
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard line.hasPrefix("KIMI_API_KEY=") else { continue }
            let value = line.dropFirst("KIMI_API_KEY=".count).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func base(env: [String: String]) -> URL? {
        let s = (env["KIMI_BASE_URL"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultBase)
        guard s.hasPrefix("https://") || s.hasPrefix("http://") else { return nil }
        return URL(string: s.hasSuffix("/") ? String(s.dropLast()) : s)
    }

    /// "5-hour" from {duration: 300, timeUnit: TIME_UNIT_MINUTE}; minutes for the window length.
    static func window(_ w: [String: Any]) -> (name: String, minutes: Double)? {
        guard let n = plainNumber(w["duration"]) ?? double(w["duration"]), n > 0 else { return nil }
        let unit = (w["timeUnit"] as? String ?? "").replacingOccurrences(of: "TIME_UNIT_", with: "").lowercased()
        let perUnit: [String: Double] = ["minute": 1, "hour": 60, "day": 1440, "week": 10080]
        guard let k = perUnit[unit] else { return nil }
        let minutes = n * k
        return (limitName(minutes: minutes), minutes)
    }

    /// The quota from a /usages reply. `limits[]` is the request window that
    /// actually cuts you off (8 of 100 in five hours) and wins its span; the
    /// credit ratio `usages` carries for the same span is dropped, not shown twice.
    /// The monthly total is the plan window; the monthly code figure rides along.
    public static func parseUsages(_ data: Data, measuredMs: Double, calendar: Calendar = .current) -> AgentLimits {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return AgentLimits(status: "Kimi usage reply not understood")
        }
        var windows: [LimitReading] = []
        var spans = Set<String>()
        for case let entry as [String: Any] in obj["limits"] as? [Any] ?? [] {
            guard let w = (entry["window"] as? [String: Any]).flatMap(window),
                  let detail = entry["detail"] as? [String: Any],
                  let limit = double(detail["limit"]), limit > 0,
                  let used = double(detail["used"]), used.isFinite else { continue }
            guard !spans.contains(w.name) else { continue }
            spans.insert(w.name)
            windows.append(LimitReading(name: w.name, kind: w.minutes <= 24 * 60 ? .session : .plan,
                                        percent: max(0, min(1, used / limit)), resetsMs: parseTimestamp(detail["resetTime"]),
                                        windowMs: w.minutes * 60_000, measuredMs: measuredMs))
        }
        let usages = obj["usages"] as? [String: Any] ?? [:]
        let named: [(key: String, name: String, kind: LimitKind, span: String?)] = [
            ("limit_5h", "5-hour", .session, "5-hour"),
            ("limit_month_total", "Monthly", .plan, nil),
            ("limit_month_code", "Monthly code", .extra, nil),
        ]
        for n in named {
            guard let entry = usages[n.key] as? [String: Any] else { continue }
            if let span = n.span, spans.contains(span) { continue }
            guard let ratio = double(entry["used_ratio"]), ratio.isFinite else { continue }
            let reset = parseTimestamp(entry["reset_time"])
            var span: Double? = n.kind == .session ? 5 * hourMs : nil
            if span == nil, let r = reset,
               let start = calendar.date(byAdding: .month, value: -1, to: Date(timeIntervalSince1970: r / 1000)) {
                span = r - start.timeIntervalSince1970 * 1000
            }
            windows.append(LimitReading(name: n.name, kind: n.kind, percent: max(0, min(1, ratio)),
                                        resetsMs: reset, windowMs: span, measuredMs: measuredMs))
        }
        if windows.isEmpty { return AgentLimits(status: "No limits in the Kimi usage reply") }
        // A request window longer than a day is the plan only when no monthly figure came back.
        if windows.contains(where: { $0.name == "Monthly" }) {
            for i in windows.indices where windows[i].kind == .plan && windows[i].name != "Monthly" { windows[i].kind = .extra }
        }
        return AgentLimits(windows: windows)
    }

    /// The tier and the key owner from a /me reply. Only those two fields are kept.
    public static func parseMe(_ data: Data) -> (tier: String?, account: String?) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (nil, nil) }
        let tier = (obj["user_level_name"] as? String).map { String($0.prefix(40)) }.flatMap { $0.isEmpty ? nil : $0 }
        return (tier, cleanAccount(obj["email"]) ?? cleanAccount(obj["nickname"]))
    }

    public struct Reading: Sendable {
        public var limits: AgentLimits
        public var account: String?
    }

    /// Both calls, nil when no key is set (the lane then shows tokens only).
    /// `me` is skipped when the caller already holds a fresh tier and account.
    public static func fetch(me wantMe: Bool = true, env: [String: String] = ProcessInfo.processInfo.environment) async -> Reading? {
        guard let key = apiKey(env: env) else { return nil }
        guard let base = base(env: env) else { return Reading(limits: AgentLimits(status: "KIMI_BASE_URL is not an http(s) URL")) }
        func get(_ path: String) async -> (Data, Int)? {
            var req = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 10)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
            return (data.prefix(256 << 10), (resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        var out = Reading(limits: AgentLimits())
        switch await get("usages") {
        case nil: out.limits = AgentLimits(status: "Kimi usage service unreachable")
        case let (_, code)? where code == 401 || code == 403: out.limits = AgentLimits(status: "Kimi rejected the key: check KIMI_API_KEY in ~/.env")
        case let (data, 200)?: out.limits = parseUsages(data, measuredMs: Date().timeIntervalSince1970 * 1000)
        case let (_, code)?: out.limits = AgentLimits(status: "Kimi usage service answered \(code)")
        }
        if wantMe, let r = await get("me"), r.1 == 200 {
            let me = parseMe(r.0)
            out.limits.plan = me.tier
            out.account = me.account
        }
        return out
    }
}
