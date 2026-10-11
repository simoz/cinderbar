import Foundation

// Budget means an even spend across the window. Two numbers decide everything:
// how much of the plan is used, and how much of the clock. Ported from Burn
// Bar's paceLive / guidePick so the advice keeps the same rules.

public let hourMs: Double = 3_600_000
public let dayMs: Double = 24 * hourMs
public let weekMs: Double = 7 * dayMs

public struct PaceLive: Equatable, Sendable {
    public var used: Double        // 0...1 of the plan
    public var elapsed: Double     // 0...1 of the clock
    public var leftMs: Double
    public var windowMs: Double
    public var resetsMs: Double
    public var banked: Double = 0
    public var bankedMs: Double = 0
    public var behind: Double = 0
    public var over = false
    public var comeBackAt: Double = 0
    public var comeBackMs: Double = 0
    public var room: Double = 0
    public var spent: Bool

    public enum Stance: Equatable, Sendable { case ahead, onPace, behind, spent }

    public var stance: Stance {
        if spent { return .spent }
        if over { return .behind }
        if banked > 0.005 { return .ahead }
        return .onPace
    }

    /// The verdict pill: ON TRACK, AT PACE, OVER or WAY OVER. Over starts 5%
    /// past an even spend, the same line `over` uses, so they never disagree.
    public var verdict: String {
        if spent { return "SPENT" }
        if !over { return banked > 0.005 ? "ON TRACK" : "AT PACE" }
        let ratio = elapsed > 0 ? used / elapsed : .infinity
        return ratio >= 1.5 ? "WAY OVER" : "OVER"
    }
}

/// `percent` is 0...1. Returns nil for anything that cannot be read, so nothing
/// is ever claimed about a window that cannot be measured.
public func paceLive(_ percent: Double?, resetsMs: Double?, windowMs: Double?, nowMs: Double) -> PaceLive? {
    guard let p0 = percent, let reset = resetsMs, let span = windowMs,
          p0 >= 0, reset > 0, span > 0, nowMs > 0, nowMs < reset else { return nil }
    let p = min(1, p0)
    let left = reset - nowMs
    let e = max(0, min(1, 1 - left / span))
    var out = PaceLive(used: p, elapsed: e, leftMs: left, windowMs: span, resetsMs: reset, spent: p >= 0.995)
    if out.spent {
        // Decided first: a plan can be spent while still "ahead" of the clock,
        // and it only ever comes back at its reset.
        out.behind = max(0, p - e)
        out.over = true
        out.comeBackAt = reset
        out.comeBackMs = left
    } else if e > p {
        out.banked = e - p
        out.bankedMs = out.banked * span
    } else if p > e {
        out.behind = p - e
        // More than 5% past an even spend, and by at least a whole percent.
        out.over = out.behind > 0.01 && (e <= 0 || p / e > 1.05)
        // Stop now and the even-spend line catches up when elapsed reaches used.
        out.comeBackAt = min(reset, reset - span * (1 - p))
        out.comeBackMs = max(0, out.comeBackAt - nowMs)
    }
    // Plan left over clock left: 1 is on pace, 2 means the rest of the window
    // can take twice an even spend. Comparable between a week and a month.
    out.room = e < 1 ? (1 - p) / (1 - e) : 0
    return out
}

public struct GuideRow: Sendable {
    public var id: String
    public var live: PaceLive?
    public var fresh: Bool
    public var blocked: Bool
    /// A snapshot that may have been outrun needs a bigger margin.
    public var minBank: Double

    public init(id: String, live: PaceLive?, fresh: Bool = true, blocked: Bool = false, minBank: Double = 0) {
        self.id = id; self.live = live; self.fresh = fresh; self.blocked = blocked; self.minBank = minBank
    }
}

public struct Resting: Equatable, Sendable {
    public var id: String
    public var comeBackAt: Double
    public var spent: Bool
    public var behind: Double
}

public struct Guidance: Equatable, Sendable {
    public var count = 0
    public var pick = ""
    public var next = ""
    public var urgent = false
    public var room: Double = 0
    public var rest: [Resting] = []
    public var ahead = 0
    public init() {}
}

public func guidePick(_ rows: [GuideRow], previous: String = "") -> Guidance {
    let minBankDefault = 0.02, stick = 1.15
    // "Use it or lose it" is about the calendar, not the window.
    let loseItMs = 72 * hourMs, loseItShare = 0.15, loseItLeft = 0.10
    var out = Guidance()
    var ok: [(id: String, live: PaceLive)] = []
    for r in rows where !r.id.isEmpty {
        out.count += 1
        guard let live = r.live, r.fresh else { continue }
        if live.over || live.spent {
            out.rest.append(Resting(id: r.id, comeBackAt: live.comeBackAt, spent: live.spent, behind: live.behind))
        }
        var need = r.minBank > 0 ? r.minBank : minBankDefault
        if r.id == previous { need *= 0.5 }
        if live.spent || r.blocked || !(live.banked >= need) { continue }
        ok.append((r.id, live))
    }
    out.ahead = ok.count
    out.rest.sort { $0.comeBackAt < $1.comeBackAt }
    if out.count < 2 || ok.isEmpty { return out }
    ok.sort { a, b in
        if a.live.room != b.live.room { return a.live.room > b.live.room }
        if a.live.banked != b.live.banked { return a.live.banked > b.live.banked }
        return a.live.leftMs < b.live.leftMs
    }
    if !previous.isEmpty, previous != ok[0].id, let i = ok.firstIndex(where: { $0.id == previous }) {
        // The challenger has to be clearly better, not better by a rounding.
        if ok[0].live.room < ok[i].live.room * stick { ok.insert(ok.remove(at: i), at: 0) }
    }
    let top = ok[0].live
    out.pick = ok[0].id
    out.room = top.room
    out.urgent = top.leftMs <= min(loseItMs, top.windowMs * loseItShare) && (1 - top.used) >= loseItLeft
    out.next = ok.count > 1 ? ok[1].id : ""
    return out
}

/// The 5-hour session window only matters when it is the one that bites:
/// spent, or running dry before its reset at the measured rate.
public struct SessionHeat: Equatable, Sendable {
    public var hot = false
    public var spent = false
    public var dryAt: Double = 0
    public var used: Double = -1
    public var resetsMs: Double = 0
    public init() {}
}

/// `ratePerMs` is the session percentage's measured climb (0...1 per ms), or 0 when unknown.
public func sessionHeat(used: Double?, resetsMs: Double?, windowMs: Double = 5 * hourMs,
                        ratePerMs: Double, weekSpent: Bool, nowMs: Double) -> SessionHeat {
    var calm = SessionHeat()
    if weekSpent { return calm }
    guard let live = paceLive(used, resetsMs: resetsMs, windowMs: windowMs, nowMs: nowMs) else { return calm }
    calm.used = live.used
    calm.resetsMs = live.resetsMs
    var dryAt: Double = 0
    if ratePerMs > 0 { dryAt = nowMs + (1 - live.used) / ratePerMs }
    let dry = dryAt > nowMs && dryAt < live.resetsMs
    if !live.spent && !dry { return calm }
    calm.hot = true
    calm.spent = live.spent
    calm.dryAt = dry && !live.spent ? dryAt : 0
    return calm
}

/// A full session window, or one that will be full inside half an hour, blocks a sub.
public func sessionBlocks(_ heat: SessionHeat, nowMs: Double) -> Bool {
    heat.spent || (heat.dryAt > 0 && heat.dryAt - nowMs <= 30 * 60_000)
}

// MARK: - Words

public func spanWords(_ ms: Double) -> String {
    let mins = max(0, Int((ms / 60_000).rounded()))
    if mins < 1 { return "under a minute" }
    let d = mins / 1440, h = (mins % 1440) / 60, m = mins % 60
    if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
    if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
    return "\(m)m"
}

public func clockSpan(_ ms: Double) -> String {
    guard ms.isFinite else { return "0:00" }
    let total = max(0, Int(ms / 1000))
    let d = total / 86400, h = (total % 86400) / 3600, m = (total % 3600) / 60, s = total % 60
    func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
    if d > 0 { return "\(d)d \(two(h)):\(two(m)):\(two(s))" }
    if h > 0 { return "\(h):\(two(m)):\(two(s))" }
    return "\(m):\(two(s))"
}

public func spanShort(_ ms: Double) -> String {
    guard ms.isFinite else { return "1M" }
    let mins = max(1, Int((ms / 60_000).rounded()))
    if mins >= 1440 { return "\(Int((Double(mins) / 1440).rounded()))D" }
    if mins >= 60 { return "\(Int((Double(mins) / 60).rounded()))H" }
    return "\(mins)M"
}

public func tokenWords(_ n: Int) -> String {
    let v = Double(n)
    if v >= 1e9 { return String(format: "%.1fB", v / 1e9) }
    if v >= 1e6 { return String(format: "%.1fM", v / 1e6) }
    if v >= 1e4 { return String(format: "%.0fK", v / 1e3) }
    if v >= 1e3 { return String(format: "%.1fK", v / 1e3) }
    return "\(n)"
}
