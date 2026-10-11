import Foundation

/// Where one subscription stands, everything a card and the strip need.
public struct Standing: Equatable, Sendable {
    public var agent: Agent
    public var plan: LimitReading?
    public var live: PaceLive?
    public var session: LimitReading?
    public var heat = SessionHeat()
    public var blocked = false
    public var fresh = false
    /// How long ago the plan figure was measured.
    public var ageMs: Double = 0
    public init(agent: Agent) { self.agent = agent }
}

public struct Advice: Equatable, Sendable {
    public var standings: [Agent: Standing] = [:]
    public var guidance = Guidance()
    public init() {}
}

/// A re-measured figure (Claude) older than this is withheld from guidance.
public let staleAfterMs: Double = 6 * hourMs

public func advise(_ snap: Snapshot, enabled: [Agent], history: PaceHistory, previous: String, now: Double) -> Advice {
    var out = Advice()
    var rows: [GuideRow] = []
    for agent in enabled {
        guard let stats = snap.agents[agent], stats.present else { continue }
        var st = Standing(agent: agent)
        st.plan = stats.limits.planWindow
        st.session = stats.limits.sessionWindow
        st.live = st.plan?.live(now: now)
        st.ageMs = st.plan.map { max(0, now - $0.measuredMs) } ?? 0
        // Claude is re-measured every few minutes, so an old figure means the
        // probe is failing. Codex only reports when Codex runs, so its last
        // figure stands until its window resets: usage cannot climb unmeasured
        // on this Mac, only elsewhere.
        let snapshotSource = agent == .codex
        st.fresh = st.live != nil && stats.limits.status == nil && (snapshotSource || st.ageMs < staleAfterMs)
        if let s = st.session {
            let rate = history.rate(agent, s.name, now: now)
            st.heat = sessionHeat(used: s.rolledOver(now: now) ? nil : s.percent, resetsMs: s.resetsMs,
                                  windowMs: s.windowMs ?? 5 * hourMs, ratePerMs: rate,
                                  weekSpent: st.live?.spent ?? false, nowMs: now)
            st.blocked = sessionBlocks(st.heat, nowMs: now)
        }
        out.standings[agent] = st
        // A reading taken a while ago may have been outrun elsewhere, so it
        // needs five times the margin before it is suggested.
        let minBank = st.ageMs > 30 * 60_000 ? 0.10 : 0
        rows.append(GuideRow(id: agent.rawValue, live: st.live, fresh: st.fresh, blocked: st.blocked, minBank: minBank))
    }
    out.guidance = guidePick(rows, previous: previous)
    return out
}

/// The line that leads every card: what to do about this subscription.
public struct TodoLine: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case good, calm, warn, bad, unknown }
    public var headline: String
    public var detail: String
    public var tone: Tone
}

public func todoLine(_ st: Standing, now: Double, calendar: Calendar = .current) -> TodoLine {
    guard let live = st.live else {
        if st.plan?.rolledOver(now: now) == true {
            return TodoLine(headline: "ROLLED OVER", detail: "new window, waiting for a fresh reading", tone: .unknown)
        }
        return TodoLine(headline: "NO PLAN READING", detail: "showing tokens only", tone: .unknown)
    }
    let asOf = st.ageMs > 30 * 60_000 ? " · as of \(dayTime(now - st.ageMs, now: now, calendar: calendar))" : ""
    switch live.stance {
    case .spent:
        return TodoLine(headline: "BACK AT THE RESET",
                        detail: "\(dayTime(live.resetsMs, now: now, calendar: calendar)) · in \(clockSpan(live.leftMs))", tone: .bad)
    case .behind:
        let pct = Int((live.behind * 100).rounded())
        return TodoLine(headline: "COME BACK IN \(clockSpan(live.comeBackMs))",
                        detail: "if you stop · \(dayTime(live.comeBackAt, now: now, calendar: calendar)) · \(pct)% over\(asOf)",
                        tone: .warn)
    case .ahead:
        let pct = Int((live.banked * 100).rounded())
        let approx = st.ageMs > 30 * 60_000 ? "~" : ""
        return TodoLine(headline: "BANKED \(approx)\(pct)%", detail: "\(clockSpan(live.bankedMs)) in the bank\(asOf)", tone: .good)
    case .onPace:
        return TodoLine(headline: "ON PACE", detail: "within 5% of an even spend\(asOf)", tone: .calm)
    }
}

/// The banner above the cards. Says nothing when there is nothing to choose.
public struct Banner: Equatable, Sendable {
    public var headline: String
    public var detail: String
    public var urgent: Bool
    public var pick: Agent?
}

public func banner(_ advice: Advice, burning: Agent?, now: Double, calendar: Calendar = .current) -> Banner? {
    let g = advice.guidance
    guard g.count >= 2 else { return nil }
    let restLine = g.rest.compactMap { r -> String? in
        guard let a = Agent(rawValue: r.id) else { return nil }
        return "\(a.title) back \(r.spent ? "at reset " : "")\(dayTime(r.comeBackAt, now: now, calendar: calendar))"
    }.joined(separator: " · ")
    guard let pick = Agent(rawValue: g.pick), let st = advice.standings[pick], let live = st.live else {
        return Banner(headline: g.rest.isEmpty ? "NO CLEAR PICK" : "EVERYONE NEEDS A REST",
                      detail: g.rest.isEmpty ? "no subscription is far enough ahead to suggest" : restLine,
                      urgent: false, pick: nil)
    }
    let verb = g.urgent ? "USE \(pick.title) NOW" : (burning == pick ? "KEEP USING \(pick.title)" : "USE \(pick.title) NEXT")
    var why = g.urgent
        ? "use it or lose it: \(Int(((1 - live.used) * 100).rounded()))% left · resets in \(spanWords(live.leftMs))"
        : "\(Int((live.banked * 100).rounded()))% banked, about \(spanWords(live.bankedMs)) ahead · resets in \(spanWords(live.leftMs))"
    if let next = Agent(rawValue: g.next) { why += " · then \(next.title)" }
    if !restLine.isEmpty { why += " · " + restLine }
    return Banner(headline: verb, detail: why, urgent: g.urgent, pick: pick)
}

/// The chip beside the strip: a warning while something is past an even
/// spend, otherwise the sub to use next.
public struct Chip: Equatable, Sendable {
    public var agent: Agent
    public var text: String
    public var warning: Bool
    /// Severity used to decide whether a dismissed chip comes back.
    public var stage: Int
}

public func chip(_ advice: Advice, enabled: [Agent], showAdvice: Bool, now: Double) -> Chip? {
    var worst: Chip?
    for agent in enabled {
        guard let st = advice.standings[agent] else { continue }
        var c: Chip?
        // The 5-hour window outranks a week merely over pace: it locks you out in hours.
        if st.heat.hot {
            if st.heat.spent {
                c = Chip(agent: agent, text: "\(agent.title) 5H SPENT, BACK \(spanShort(st.heat.resetsMs - now))", warning: true, stage: 4)
            } else if st.heat.dryAt > now {
                c = Chip(agent: agent, text: "\(agent.title) 5H OUT IN \(spanShort(st.heat.dryAt - now))", warning: true, stage: 3)
            }
        }
        if let live = st.live, st.fresh {
            if live.spent {
                c = Chip(agent: agent, text: "\(agent.title) SPENT", warning: true, stage: 5)
            } else if live.over, c == nil {
                let way = live.elapsed > 0 && live.used / live.elapsed >= 1.5
                c = Chip(agent: agent, text: "\(agent.title) REST \(spanShort(live.comeBackMs))", warning: true, stage: way ? 2 : 1)
            }
        }
        if let c, c.stage > (worst?.stage ?? 0) { worst = c }
    }
    if let worst { return worst }
    if showAdvice, let pick = Agent(rawValue: advice.guidance.pick) {
        return Chip(agent: pick, text: advice.guidance.urgent ? "USE \(pick.title) NOW" : "USE \(pick.title)", warning: false, stage: 0)
    }
    return nil
}

// MARK: - Clock words

/// "4:10 PM" today, "Sun 10:55 PM" within a week, "Oct 20 9:00 AM" beyond.
public func dayTime(_ ms: Double, now: Double, calendar: Calendar = .current) -> String {
    let d = Date(timeIntervalSince1970: ms / 1000), n = Date(timeIntervalSince1970: now / 1000)
    let f = DateFormatter()
    f.calendar = calendar
    f.timeZone = calendar.timeZone
    f.locale = Locale(identifier: "en_US_POSIX")
    if calendar.isDate(d, inSameDayAs: n) { f.dateFormat = "h:mm a" }
    else if abs(ms - now) < 6 * dayMs { f.dateFormat = "EEE h:mm a" }
    else { f.dateFormat = "MMM d h:mm a" }
    return f.string(from: d)
}
