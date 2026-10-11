import Foundation

/// Claude: `~/.claude/projects/**/*.jsonl`, assistant lines carry
/// `message.usage`. The same message is re-serialized as it streams, each
/// revision with more output, so `message.id` is the dedupe key and the
/// largest revision is the one that counts (done in the collector).
public func claudeExtract(_ line: [String: Any], _ state: inout ExtractState, _ session: String) -> LineYield {
    guard line["type"] as? String == "assistant",
          let message = line["message"] as? [String: Any],
          let usage = message["usage"] as? [String: Any],
          let ts = parseTimestamp(line["timestamp"]) else { return LineYield() }
    let model = message["model"] as? String ?? ""
    if model == "<synthetic>" { return LineYield() }
    let split = TokenSplit(input: int(usage["input_tokens"]),
                           cacheWrite: int(usage["cache_creation_input_tokens"]),
                           output: int(usage["output_tokens"]),
                           cacheRead: int(usage["cache_read_input_tokens"]))
    if split.heat == 0 && split.cacheRead == 0 { return LineYield() }
    let key = (message["id"] as? String) ?? (line["requestId"] as? String) ?? (line["uuid"] as? String)
    let sess = line["sessionId"] as? String ?? session
    return LineYield(points: [UsagePoint(ts: ts, split: split, model: model, session: sess, key: key)])
}

/// Codex: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. `token_count`
/// events carry `info.total_token_usage`, a cumulative counter, and deltas of
/// it are what gets counted: a rate-limit refresh re-emits the same
/// `last_token_usage` with an unchanged total. The same events carry
/// `rate_limits`, which is where the plan meter comes from.
public func codexExtract(_ line: [String: Any], _ state: inout ExtractState, _ session: String) -> LineYield {
    guard let payload = line["payload"] as? [String: Any] else { return LineYield() }
    let type = line["type"] as? String
    if type == "turn_context" {
        if let m = payload["model"] as? String, !m.isEmpty { state.model = m }
        return LineYield()
    }
    guard type == "event_msg", payload["type"] as? String == "token_count",
          let ts = parseTimestamp(line["timestamp"]) else { return LineYield() }
    var out = LineYield()
    if let rl = payload["rate_limits"] as? [String: Any] {
        out.limits = codexLimits(rl, measuredMs: ts)
    }
    if let info = payload["info"] as? [String: Any], let total = info["total_token_usage"] as? [String: Any] {
        let cached = int(total["cached_input_tokens"])
        let now = TokenSplit(input: max(0, int(total["input_tokens"]) - cached),
                             cacheWrite: int(total["cache_write_input_tokens"]),
                             output: int(total["output_tokens"]),
                             cacheRead: cached)
        var delta = now
        if let last = state.lastTotal {
            let d = TokenSplit(input: now.input - last.input, cacheWrite: now.cacheWrite - last.cacheWrite,
                               output: now.output - last.output, cacheRead: now.cacheRead - last.cacheRead)
            // A counter that went backwards was reset; count the new total.
            delta = (d.input < 0 || d.output < 0 || d.cacheRead < 0 || d.cacheWrite < 0) ? now : d
        }
        state.lastTotal = now
        if delta.heat > 0 || delta.cacheRead > 0 {
            out.points.append(UsagePoint(ts: ts, split: delta, model: state.model.isEmpty ? "codex" : state.model,
                                         session: session, key: nil))
        }
    }
    return out
}

func codexLimits(_ rl: [String: Any], measuredMs: Double) -> AgentLimits {
    var windows: [LimitReading] = []
    for key in ["primary", "secondary"] {
        guard let w = rl[key] as? [String: Any] else { continue }
        let minutes = double(w["window_minutes"])
        let windowMs = minutes.map { $0 * 60_000 }
        let resets = double(w["resets_at"]).map { $0 > 1e12 ? $0 : $0 * 1000 }
        let kind: LimitKind = (minutes ?? 0) <= 24 * 60 ? .session : .plan
        windows.append(LimitReading(name: limitName(minutes: minutes), kind: kind,
                                    percent: double(w["used_percent"]).map { $0 / 100 },
                                    resetsMs: resets, windowMs: windowMs, measuredMs: measuredMs))
    }
    return AgentLimits(windows: windows, status: nil, plan: rl["plan_type"] as? String)
}

func limitName(minutes: Double?) -> String {
    guard let m = minutes else { return "Window" }
    if m == 300 { return "5-hour" }
    if m == 10080 { return "Weekly" }
    if m >= 40000 { return "Monthly" }
    return spanWords(m * 60_000)
}
