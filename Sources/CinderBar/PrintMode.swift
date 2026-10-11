import Foundation
import CinderBarCore

/// `CinderBar --print`: one collector run, a plain summary, exit. For checking what
/// the strip is seeing without opening the panel.
enum PrintMode {
    static func runIfAsked() {
        let args = CommandLine.arguments
        guard args.contains("--print") else { return }
        let collector = Collector(cacheURL: nil)
        var cfg = CollectorConfig()
        cfg.windowMs = Double(UserDefaults.standard.integer(forKey: "windowMinutes").nonZero ?? 360) * 60_000
        var snap = collector.collect(cfg)
        if !args.contains("--no-limits") {
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                let l = await ClaudeLimits.fetch()
                snap.agents[.claude]?.limits = l
                sem.signal()
            }
            sem.wait()
        }
        let now = snap.takenMs
        print("window \(spanWords(snap.windowMs)) · scan \(Int(snap.scanMs)) ms")
        for agent in Agent.allCases {
            guard let s = snap.agents[agent] else { continue }
            print("\n\(agent.title)\(s.present ? "" : " (no transcripts)")")
            print("  tokens \(tokenWords(s.total)) · \(s.turns) turns · \(s.sessions) sessions · cache reads \(tokenWords(s.split.cacheRead))")
            print("  cells  \(s.buckets.map(tokenWords).joined(separator: " "))")
            print("  models \(s.byModel.prefix(4).map { "\($0.model) \(tokenWords($0.tokens))" }.joined(separator: ", "))")
            if let st = s.limits.status { print("  limits: \(st)") }
            for w in s.limits.windows {
                let pct = w.percent.map { "\(Int(($0 * 100).rounded()))%" } ?? "--"
                let reset = w.resetsMs.map { dayTime($0, now: now) } ?? "?"
                print("  \(w.name): \(pct) · resets \(reset) · measured \(spanWords(now - w.measuredMs)) ago\(w.rolledOver(now: now) ? " · rolled over" : "")")
            }
        }
        let adv = advise(snap, enabled: Agent.allCases, history: PaceHistory(), previous: "", now: now)
        for agent in Agent.allCases {
            if let st = adv.standings[agent] { let t = todoLine(st, now: now); print("\n\(agent.title): \(t.headline) · \(t.detail)") }
        }
        if let b = banner(adv, burning: nil, now: now) { print("\nBANNER: \(b.headline) · \(b.detail)") }
        if let c = chip(adv, enabled: Agent.allCases, showAdvice: true, now: now) { print("CHIP: \(c.text)") }
        exit(0)
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
