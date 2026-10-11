import Foundation
import EmberCore

// A tiny test runner: XCTest and swift-testing need a full Xcode, this needs
// only the Command Line Tools. `swift run ember-checks`, exits non-zero on failure.

var failures = 0, passed = 0
var current = ""

func test(_ name: String, _ body: () throws -> Void) {
    current = name
    let before = failures
    do { try body() } catch { fail("threw \(error)") }
    if failures == before { passed += 1; print("  ok  \(name)") }
}
func fail(_ msg: String, line: Int = #line) { failures += 1; print("FAIL  \(current): \(msg) (line \(line))") }
func check(_ cond: Bool, _ msg: @autoclosure () -> String = "", line: Int = #line) { if !cond { fail(msg(), line: line) } }
func eq<T: Equatable>(_ a: T, _ b: T, line: Int = #line) { if a != b { fail("\(a) != \(b)", line: line) } }
func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9, line: Int = #line) { if abs(a - b) >= eps { fail("\(a) vs \(b)", line: line) } }

let HOUR = hourMs, DAY = dayMs, WEEK = weekMs, MONTH = 30 * dayMs
let NOW: Double = 1_800_000_000_000
func win(_ used: Double, _ gone: Double, _ span: Double = WEEK) -> PaceLive? {
    paceLive(used, resetsMs: NOW + span * (1 - gone), windowMs: span, nowMs: NOW)
}
func row(_ id: String, _ used: Double, _ gone: Double, span: Double = WEEK, fresh: Bool = true, blocked: Bool = false, minBank: Double = 0) -> GuideRow {
    GuideRow(id: id, live: win(used, gone, span), fresh: fresh, blocked: blocked, minBank: minBank)
}

print("pace")

test("ahead: banked is elapsed minus used, in plan share and in time") {
    let w = win(0.02, 0.51)!
    near(w.banked, 0.49); near(w.bankedMs, 0.49 * WEEK, 1)
    eq(w.behind, 0); eq(w.comeBackAt, 0)
    near(w.room, 0.98 / 0.49)
}

test("behind: no banked figure, and a moment to come back") {
    let w = win(0.09, 0.05)!
    eq(w.banked, 0); eq(w.bankedMs, 0)
    near(w.behind, 0.04)
    near(w.comeBackMs, 0.04 * WEEK, 1)
    check(w.comeBackAt > NOW && w.comeBackAt < w.resetsMs)
}

test("time off brings a sub back") {
    let reset = NOW + 5 * DAY
    let before = paceLive(0.3, resetsMs: reset, windowMs: WEEK, nowMs: NOW)!
    let later = paceLive(0.3, resetsMs: reset, windowMs: WEEK, nowMs: NOW + 2 * DAY)!
    check(before.behind > 0 && before.banked == 0)
    check(later.banked > 0.25 && later.behind == 0)
    let flip = paceLive(0.3, resetsMs: reset, windowMs: WEEK, nowMs: before.comeBackAt + 1000)!
    eq(flip.behind, 0)
}

test("spent comes back at the reset, never before") {
    let w = win(1.0, 0.13)!
    check(w.spent); eq(w.comeBackAt, w.resetsMs); eq(w.room, 0)
}

test("spent while ahead of the clock still comes back at the reset") {
    let w = win(0.996, 0.999)!
    check(w.spent); eq(w.banked, 0); eq(w.comeBackAt, w.resetsMs); check(w.comeBackMs > 0)
    let even = win(0.997, 0.997)!
    eq(even.comeBackAt, even.resetsMs)
}

test("inside 5% of an even spend is on pace") {
    let close = win(0.50, 0.48)!
    check(close.behind > 0.019); check(!close.over)
    check(win(0.09, 0.05)!.over)
    check(!win(0.004, 0.001)!.over)
}

test("nothing is claimed about a window that cannot be read") {
    check(paceLive(-1, resetsMs: NOW + DAY, windowMs: WEEK, nowMs: NOW) == nil)
    check(paceLive(.nan, resetsMs: NOW + DAY, windowMs: WEEK, nowMs: NOW) == nil)
    check(paceLive(0.5, resetsMs: 0, windowMs: WEEK, nowMs: NOW) == nil)
    check(paceLive(0.5, resetsMs: NOW + DAY, windowMs: 0, nowMs: NOW) == nil)
    check(paceLive(0.5, resetsMs: NOW - 1, windowMs: WEEK, nowMs: NOW) == nil)
    check(paceLive(nil, resetsMs: nil, windowMs: nil, nowMs: NOW) == nil)
}

print("guidance")

test("one subscription is never suggested") {
    let g = guidePick([row("kimi", 0.05, 0.6, span: MONTH)])
    eq(g.count, 1); eq(g.pick, "")
}

test("with two, the one with room is the right one") {
    let g = guidePick([row("claude", 0.09, 0.05), row("grok", 0.02, 0.51)])
    eq(g.pick, "grok"); eq(g.next, ""); eq(g.rest.map(\.id), ["claude"])
}

test("with four, a week and a month are ranked on the same scale") {
    let g = guidePick([row("claude", 0.09, 0.05), row("codex", 1.0, 0.13),
                       row("grok", 0.02, 0.51), row("kimi", 0.05, 0.16, span: MONTH)])
    eq(g.pick, "grok"); eq(g.next, "kimi"); eq(g.ahead, 2)
    eq(g.rest.map(\.id), ["claude", "codex"])
}

test("use it or lose it") {
    let g = guidePick([row("grok", 0.02, 0.51), row("codex", 0.60, 0.95)])
    eq(g.pick, "codex"); check(g.urgent)
}

test("urgent is about the calendar") {
    let four = 1 - (4 * DAY) / MONTH, two = 1 - (2 * DAY) / MONTH
    let g = guidePick([row("kimi", 0.30, four, span: MONTH), row("claude", 0.9, 0.5)])
    eq(g.pick, "kimi"); check(!g.urgent)
    check(guidePick([row("kimi", 0.30, two, span: MONTH), row("claude", 0.9, 0.5)]).urgent)
    check(!guidePick([row("grok", 0.93, 0.97), row("claude", 0.9, 0.5)]).urgent)
}

test("a snapshot has to be further ahead before it is suggested") {
    func snap(_ bank: Double, _ min: Double) -> GuideRow { row("grok", 0.5 - bank, 0.5, minBank: min) }
    eq(guidePick([snap(0.06, 0.10), row("claude", 0.9, 0.5)]).pick, "")
    eq(guidePick([snap(0.12, 0.10), row("claude", 0.9, 0.5)]).pick, "grok")
    eq(guidePick([snap(0.12, 0.25), row("claude", 0.9, 0.5)]).pick, "")
}

test("the sub being suggested keeps the job down to half the threshold") {
    let thin = row("kimi", 0.485, 0.50, span: MONTH)
    eq(guidePick([thin, row("claude", 0.9, 0.5)]).pick, "")
    eq(guidePick([thin, row("claude", 0.9, 0.5)], previous: "kimi").pick, "kimi")
}

test("not suggested when stale, blocked or unreadable") {
    eq(guidePick([row("claude", 0.5, 0.5), row("grok", 0.02, 0.6, fresh: false)]).pick, "")
    eq(guidePick([row("claude", 0.1, 0.6, blocked: true), row("codex", 0.7, 0.5)]).pick, "")
    eq(guidePick([GuideRow(id: "claude", live: nil), row("kimi", 0.05, 0.4, span: MONTH)]).pick, "kimi")
}

test("everyone behind: no suggestion, first one back is named") {
    let g = guidePick([row("claude", 0.30, 0.10), row("codex", 0.20, 0.15)])
    eq(g.pick, ""); eq(g.rest.first?.id, "codex")
}

test("a hair of banked budget is not advice") {
    eq(guidePick([row("claude", 0.49, 0.50), row("codex", 0.30, 0.31)]).pick, "")
}

test("the advice does not flap") {
    let a = row("grok", 0.20, 0.60), b = row("kimi", 0.19, 0.60, span: MONTH)
    eq(guidePick([a, b]).pick, "kimi")
    eq(guidePick([a, b], previous: "grok").pick, "grok")
    eq(guidePick([a, row("kimi", 0.02, 0.60, span: MONTH)], previous: "grok").pick, "kimi")
}

test("clocks run and the chip stays short") {
    eq(clockSpan(3 * DAY + 9 * HOUR + 12 * 60e3 + 45e3), "3d 09:12:45")
    eq(clockSpan(7 * HOUR + 13 * 60e3 + 22e3), "7:13:22")
    eq(clockSpan(13 * 60e3 + 5e3), "13:05")
    eq(clockSpan(-5), "0:00")
    eq(clockSpan(.nan), "0:00")
    eq(spanShort(7 * HOUR + 13 * 60e3), "7H")
    eq(spanShort(2 * DAY + 3 * HOUR), "2D")
    eq(spanWords(20e3), "under a minute")
    eq(spanWords(3 * DAY + 10 * HOUR), "3d 10h")
}

print("session window")

test("a session running dry before its reset blocks the sub") {
    let reset = NOW + 2 * HOUR
    // 80% used, climbing 10% per 20 minutes: dry in 40 minutes, before the reset.
    let rate = 0.10 / (20 * 60e3)
    let h = sessionHeat(used: 0.8, resetsMs: reset, ratePerMs: rate, weekSpent: false, nowMs: NOW)
    check(h.hot); check(!h.spent); near(h.dryAt, NOW + 40 * 60e3, 1)
    check(!sessionBlocks(h, nowMs: NOW))
    check(sessionBlocks(h, nowMs: NOW + 15 * 60e3))
    let calm = sessionHeat(used: 0.7, resetsMs: reset, ratePerMs: 0, weekSpent: false, nowMs: NOW)
    check(!calm.hot)
    let spent = sessionHeat(used: 1.0, resetsMs: reset, ratePerMs: 0, weekSpent: false, nowMs: NOW)
    check(spent.spent && sessionBlocks(spent, nowMs: NOW))
}

print("transcripts")

func tmpDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("ember-checks-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
func iso(_ ms: Double) -> String {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date(timeIntervalSince1970: ms / 1000))
}
func claudeLine(_ id: String, _ ts: Double, out: Int) -> String {
    #"{"type":"assistant","timestamp":"\#(iso(ts))","sessionId":"s1","message":{"id":"\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":\#(out)}}}"#
}
func codexLine(_ ts: Double, input: Int, cached: Int, output: Int, used: Double = 12.5) -> String {
    #"{"timestamp":"\#(iso(ts))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":0,"output_tokens":\#(output)}},"rate_limits":{"primary":{"used_percent":40.0,"window_minutes":300,"resets_at":\#(Int(ts / 1000) + 3600)},"secondary":{"used_percent":\#(used),"window_minutes":10080,"resets_at":\#(Int(ts / 1000) + 86400 * 3)},"plan_type":"plus"}}}"#
}

test("claude: streamed revisions of one message count once, the largest") {
    let root = tmpDir(), now = Date().timeIntervalSince1970 * 1000
    let proj = root.appendingPathComponent("proj"); try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
    let lines = [claudeLine("m1", now - 60e3, out: 5), claudeLine("m1", now - 59e3, out: 50), claudeLine("m2", now - 30e3, out: 7)]
    try (lines.joined(separator: "\n") + "\n").write(to: proj.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
    var cfg = CollectorConfig(); cfg.claudeRoot = root; cfg.codexRoot = root.appendingPathComponent("none")
    let snap = Collector(cacheURL: nil).collect(cfg, now: now)
    let c = snap.agents[.claude]!
    eq(c.turns, 2)
    eq(c.total, (10 + 100 + 50) + (10 + 100 + 7))
    eq(c.split.cacheRead, 2000)
    eq(c.buckets.reduce(0, +), c.total)
    eq(c.byModel.first?.model, "claude-opus-5-5")
}

test("codex: deltas of the cumulative counter, and the newest rate limits") {
    let root = tmpDir(), now = Date().timeIntervalSince1970 * 1000
    let lines = [
        #"{"timestamp":"\#(iso(now - 120e3))","type":"turn_context","payload":{"model":"gpt-5.5-codex"}}"#,
        codexLine(now - 100e3, input: 1000, cached: 400, output: 50),
        codexLine(now - 90e3, input: 1000, cached: 400, output: 50),           // refresh, unchanged total
        codexLine(now - 80e3, input: 3000, cached: 1400, output: 150, used: 20),
    ]
    try (lines.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("rollout-x.jsonl"), atomically: true, encoding: .utf8)
    var cfg = CollectorConfig(); cfg.codexRoot = root; cfg.claudeRoot = root.appendingPathComponent("none")
    let c = Collector(cacheURL: nil).collect(cfg, now: now).agents[.codex]!
    eq(c.turns, 2)
    eq(c.split.input, 1600); eq(c.split.cacheRead, 1400); eq(c.split.output, 150)
    eq(c.byModel.first?.model, "gpt-5.5-codex")
    eq(c.limits.planWindow?.percent, 0.20)
    eq(c.limits.sessionWindow?.name, "5-hour")
    eq(c.limits.plan, "plus")
}

test("scanner: an append is read from the offset, a rewrite from the start") {
    let root = tmpDir(), now = Date().timeIntervalSince1970 * 1000
    let file = root.appendingPathComponent("rollout-y.jsonl")
    try (codexLine(now - 100e3, input: 1000, cached: 0, output: 0) + "\n").write(to: file, atomically: true, encoding: .utf8)
    var cfg = CollectorConfig(); cfg.codexRoot = root; cfg.claudeRoot = root.appendingPathComponent("none")
    let col = Collector(cacheURL: nil)
    eq(col.collect(cfg, now: now).agents[.codex]!.total, 1000)
    // Append: the counter's delta is counted, not the whole total again.
    let h = try FileHandle(forWritingTo: file); h.seekToEndOfFile()
    h.write(Data((codexLine(now - 50e3, input: 1500, cached: 0, output: 0) + "\n").utf8)); try h.close()
    eq(col.collect(cfg, now: now).agents[.codex]!.total, 1500)
    // A partial line is left for the next read.
    let h2 = try FileHandle(forWritingTo: file); h2.seekToEndOfFile()
    h2.write(Data(#"{"timestamp":"#.utf8)); try h2.close()
    eq(col.collect(cfg, now: now).agents[.codex]!.total, 1500)
    // A longer rewrite is not mistaken for an append.
    try ([codexLine(now - 40e3, input: 9, cached: 0, output: 0), codexLine(now - 30e3, input: 10, cached: 0, output: 0)]
        .joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    eq(col.collect(cfg, now: now).agents[.codex]!.total, 10)
}

test("claude usage reply: percentages to shares, unknown fields withheld") {
    let json = #"{"five_hour":{"utilization":42.0,"resets_at":"2026-10-11T15:00:00.000Z"},"seven_day":{"utilization":10,"resets_at":"2026-10-15T09:00:00Z"},"seven_day_opus":null,"seven_day_sonnet":{"utilization":0,"resets_at":null}}"#
    let l = ClaudeLimits.parse(Data(json.utf8), measuredMs: NOW)
    eq(l.windows.map(\.name), ["5-hour", "Weekly"])
    eq(l.planWindow?.percent, 0.10)
    eq(l.sessionWindow?.percent, 0.42)
    check(l.planWindow?.resetsMs != nil)
    check(ClaudeLimits.parse(Data("nope".utf8), measuredMs: NOW).status != nil)
}

print("advice")

func standingSnap(claude: Double, codex: Double, gone: Double) -> Snapshot {
    var agents: [Agent: AgentStats] = [:]
    for (a, used) in [(Agent.claude, claude), (.codex, codex)] {
        var s = AgentStats(agent: a); s.present = true
        s.limits = AgentLimits(windows: [LimitReading(name: "Weekly", kind: .plan, percent: used,
                                                      resetsMs: NOW + WEEK * (1 - gone), windowMs: WEEK, measuredMs: NOW)])
        agents[a] = s
    }
    return Snapshot(takenMs: NOW, windowMs: 6 * HOUR, agents: agents)
}

test("banner names the sub with room and the chip warns about the other") {
    let adv = advise(standingSnap(claude: 0.6, codex: 0.1, gone: 0.4), enabled: Agent.allCases, history: PaceHistory(), previous: "", now: NOW)
    eq(adv.guidance.pick, "codex")
    let b = banner(adv, burning: nil, now: NOW)!
    eq(b.headline, "USE CODEX NEXT")
    eq(banner(adv, burning: .codex, now: NOW)!.headline, "KEEP USING CODEX")
    let c = chip(adv, enabled: Agent.allCases, showAdvice: true, now: NOW)!
    eq(c.agent, .claude); check(c.warning); check(c.text.hasPrefix("CLAUDE REST"))
    eq(todoLine(adv.standings[.codex]!, now: NOW).headline, "BANKED 30%")
    check(todoLine(adv.standings[.claude]!, now: NOW).headline.hasPrefix("COME BACK IN"))
}

test("a lane that is switched off gets no advice") {
    let adv = advise(standingSnap(claude: 0.6, codex: 0.1, gone: 0.4), enabled: [.codex], history: PaceHistory(), previous: "", now: NOW)
    eq(adv.guidance.pick, ""); check(banner(adv, burning: nil, now: NOW) == nil)
    check(adv.standings[.claude] == nil)
}

test("an old Codex reading still counts, with five times the margin; an old Claude one does not") {
    func snapAged(codexUsed: Double, age: Double) -> Snapshot {
        var s = standingSnap(claude: 0.9, codex: codexUsed, gone: 0.5)
        for a in Agent.allCases { s.agents[a]!.limits.windows[0].measuredMs = NOW - age }
        return s
    }
    let threeDays = 3 * DAY
    eq(advise(snapAged(codexUsed: 0.45, age: threeDays), enabled: Agent.allCases, history: PaceHistory(), previous: "", now: NOW).guidance.pick, "")
    let adv = advise(snapAged(codexUsed: 0.30, age: threeDays), enabled: Agent.allCases, history: PaceHistory(), previous: "", now: NOW)
    eq(adv.guidance.pick, "codex")
    check(!adv.standings[.claude]!.fresh)
    check(todoLine(adv.standings[.codex]!, now: NOW).headline.hasPrefix("BANKED ~"))
}

test("pace history: a reset starts a new track, repeats are folded") {
    var h = PaceHistory()
    func lim(_ p: Double, _ t: Double, reset: Double) -> AgentLimits {
        AgentLimits(windows: [LimitReading(name: "5-hour", kind: .session, percent: p, resetsMs: reset, windowMs: 5 * HOUR, measuredMs: t)])
    }
    let r = NOW + 3 * HOUR
    for (i, p) in [0.1, 0.1, 0.1, 0.1, 0.3].enumerated() { h.record(.claude, lim(p, NOW + Double(i) * 600e3, reset: r)) }
    eq(h.samples(.claude, "5-hour").count, 3)
    near(h.rate(.claude, "5-hour", now: NOW + 2400e3), 0.2 / 2400e3, 1e-15)
    h.record(.claude, lim(0.0, NOW + 5 * HOUR, reset: r + 5 * HOUR))
    eq(h.samples(.claude, "5-hour").count, 1)
}

print(failures == 0 ? "\n\(passed) passed" : "\n\(failures) failure(s), \(passed) passed")
exit(failures == 0 ? 0 : 1)
