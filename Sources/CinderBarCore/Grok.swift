import Foundation

// Grok (Grok Bot / Grok Build) keeps everything under $GROK_HOME, ~/.grok by
// default. Ported from Burn Bar's collector:
//
//   sessions/**/usage.json      the per-turn ledger the Grok CLI writes (1.0.52 on).
//                               Rewritten in place, so each read replaces the last;
//                               sessionId + turnNumber is the dedupe key.
//   sessions/**/updates.jsonl   `_meta.totalTokens` is the running context size
//                               for a promptId. Only for sessions without a
//                               usage.json (older Grok builds): a prompt's burn is
//                               estimated as the rise of that figure within the
//                               prompt; a flat prompt adds nothing.
//   sessions/**/summary.json    the model id, when present.
//   logs/unified.jsonl          "billing: fetched credits config" lines carry
//                               the weekly credit figure and the plan name.
//                               Grok writes one when it starts, so it is a snapshot.
//   auth.json                   one entry per sign-in, each with the email.

public enum Grok {
    public static var home: URL {
        if let env = ProcessInfo.processInfo.environment["GROK_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok")
    }

    public static let billingMessage = "billing: fetched credits config"

    /// Plan names Grok has been seen to report, lowest to highest, so a change
    /// can be called an upgrade or a downgrade. Anything else is still shown
    /// exactly as Grok wrote it; it is only left unranked.
    static let tierRank: [String: Int] = ["free": 0, "grokfree": 0, "groklite": 1, "supergroklite": 1, "supergrok": 2,
                                          "grokplus": 3, "supergrokplus": 3, "supergrokheavy": 4]

    /// "SuperGrok Heavy" -> "Heavy": the card already says GROK. A bare
    /// "SuperGrok" has nothing left to strip and stays as it is.
    public static func tierShort(_ label: String) -> String {
        let short = label.replacingOccurrences(of: #"^(?i)(super)?grok[\s_-]*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? label : short
    }

    static func rank(_ label: String) -> Int? {
        tierRank[label.lowercased().filter { $0.isLetter || $0.isNumber }]
    }

    /// A plan change only matters inside the window it happened in; an older
    /// one already belongs to last week's numbers.
    public static func currentChange(_ change: PlanChange?, plan: LimitReading?, now: Double) -> PlanChange? {
        guard let c = change, let p = plan, let reset = p.resetsMs, let span = p.windowMs else { return nil }
        return reset - span < c.atMs && c.atMs <= now ? c : nil
    }

    // MARK: Account

    /// The newest sign-in's email (else first name) from auth.json. Only that
    /// one field is kept: the same file holds tokens, which are dropped here.
    public static func account(authURL: URL? = nil) -> String? {
        guard let obj = Accounts.object(authURL ?? home.appendingPathComponent("auth.json")) else { return nil }
        var best: (stamp: String, label: String)?
        for case let entry as [String: Any] in obj.values {
            guard let label = cleanAccount(entry["email"]) ?? cleanAccount(entry["first_name"]) else { continue }
            let stamp = entry["create_time"] as? String ?? ""
            if best == nil || stamp > best!.stamp { best = (stamp, label) }
        }
        return best?.label
    }
}

/// A label that is safe to draw: one printable line, no control, zero-width
/// or bidi-override characters, at most 80 characters.
public func cleanAccount(_ value: Any?, limit: Int = 80) -> String? {
    guard let s = value as? String else { return nil }
    let kept = s.unicodeScalars.filter { u in
        switch u.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .unassigned, .surrogate, .privateUse: return false
        default: return true
        }
    }
    let text = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
    if text.isEmpty { return nil }
    return text.count <= limit ? text : String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
}

/// A JSON number that is not a boolean (JSONSerialization hands both back as NSNumber).
func plainNumber(_ v: Any?) -> Double? {
    guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
    let d = n.doubleValue
    return d.isFinite ? d : nil
}

/// A session's `usage.json`: one point per turn, keyed by session and turn
/// number. A turn listed twice keeps its last entry. Mapped like Claude: fresh
/// input is input less cache reads, and output already includes reasoning
/// (Grok's totalTokens is input + output), as with Codex. `model` is empty
/// when the file names none, for the collector to fill in.
public func grokUsagePoints(_ obj: [String: Any], session fallback: String) -> [UsagePoint] {
    let session = (obj["sessionId"] as? String).map { String($0.prefix(64)) }.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    let updated = parseTimestamp(obj["updatedAt"])
    var byTurn: [Int: UsagePoint] = [:]
    var order: [Int] = []
    for case let turn as [String: Any] in obj["turns"] as? [Any] ?? [] {
        guard let n = plainNumber(turn["turnNumber"]), n.rounded() == n, abs(n) < 1e9,
              let ts = parseTimestamp(turn["endedAt"]) ?? updated else { continue }
        let cached = int(turn["cachedReadTokens"])
        let split = TokenSplit(input: max(0, int(turn["inputTokens"]) - cached),
                               cacheWrite: int(turn["cacheCreationTokens"]),
                               output: int(turn["outputTokens"]),
                               cacheRead: cached)
        if split.heat == 0 && split.cacheRead == 0 { continue }
        let key = Int(n)
        if byTurn[key] == nil { order.append(key) }
        byTurn[key] = UsagePoint(ts: ts, split: split, model: grokTurnModel(turn), session: session,
                                 key: "\(session)/turn/\(key)")
    }
    return order.compactMap { byTurn[$0] }
}

/// primaryModelId, else the model in modelUsage that did the most.
func grokTurnModel(_ turn: [String: Any]) -> String {
    if let id = turn["primaryModelId"] as? String, !id.isEmpty { return String(id.prefix(64)) }
    let usage = turn["modelUsage"] as? [String: Any] ?? [:]
    let top = usage.max { a, b in
        int((a.value as? [String: Any])?["totalTokens"]) < int((b.value as? [String: Any])?["totalTokens"])
    }
    return top.map { String($0.key.prefix(64)) } ?? ""
}

/// One `updates.jsonl` line. Each prompt's point carries the rise of its
/// context so far, keyed by prompt, so the collector keeps the largest.
public func grokExtract(_ line: [String: Any], _ state: inout ExtractState, _ session: String) -> LineYield {
    // _meta rides on params for session/update records, else at the top level.
    let params = line["params"] as? [String: Any]
    guard let meta = (params?["_meta"] as? [String: Any]) ?? (line["_meta"] as? [String: Any]),
          let raw = plainNumber(meta["totalTokens"]), raw >= 0, raw < 1e12, raw.rounded() == raw,
          let pid = (meta["promptId"] as? String).map({ String($0.prefix(64)) }), !pid.isEmpty else { return LineYield() }
    let total = Int(raw)
    var ts = plainNumber(meta["turnStartMs"]) ?? plainNumber(meta["agentTimestampMs"])
    if ts == nil, let t = plainNumber(line["timestamp"]) { ts = t < 1e12 ? t * 1000 : t }
    guard let ts else { return LineYield() }

    var prompts = state.prompts ?? [:]
    var span = prompts[pid] ?? PromptSpan(ts: ts, min: total, max: total)
    let before = span.max - span.min
    span.min = min(span.min, total)
    span.max = max(span.max, total)
    span.ts = min(span.ts, ts)
    prompts[pid] = span
    state.prompts = prompts
    let rise = span.max - span.min
    guard rise > before else { return LineYield() }
    return LineYield(points: [UsagePoint(ts: span.ts, split: TokenSplit(input: rise), model: "grok",
                                         session: session, key: "\(session)/\(pid)")])
}

/// One `logs/unified.jsonl` billing line: the weekly credit figure and the plan.
public func grokBillingExtract(_ line: [String: Any], _ state: inout ExtractState, _ session: String) -> LineYield {
    guard line["msg"] as? String == Grok.billingMessage,
          let ctx = line["ctx"] as? [String: Any],
          let config = ctx["config"] as? [String: Any], !config.isEmpty else { return LineYield() }
    let ts = parseTimestamp(line["ts"]) ?? 0

    let tier = String((ctx["subscriptionTier"] as? String ?? "").prefix(40))
    if !tier.isEmpty, tier != state.tier {
        if let prev = state.tier, !prev.isEmpty {
            let old = Grok.rank(prev), new = Grok.rank(tier)
            let dir: PlanChange.Direction = old == nil || new == nil || old == new ? .unknown : new! > old! ? .up : .down
            state.planChange = PlanChange(from: Grok.tierShort(prev), to: Grok.tierShort(tier), atMs: ts, direction: dir)
        }
        state.tier = tier
    }

    let period = config["currentPeriod"] as? [String: Any]
    let reset = parseTimestamp(period?["end"]) ?? parseTimestamp(config["billingPeriodEnd"])
    // Grok logs 0...100. A config without the figure is unknown, never a green 0%.
    let pct = plainNumber(config["creditUsagePercent"]).flatMap { $0 >= 0 && $0 <= 100 ? $0 / 100 : nil }
    let weekly = LimitReading(name: "Weekly", kind: .plan, percent: pct, resetsMs: reset,
                              windowMs: weekMs, measuredMs: ts)
    let plan = state.tier.map(Grok.tierShort)
    return LineYield(limits: AgentLimits(windows: [weekly], status: nil, plan: plan, planChange: state.planChange))
}
