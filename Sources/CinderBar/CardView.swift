import SwiftUI
import CinderBarCore

/// One subscription: verdict, what to do, headline, burndown, the instruction,
/// every quota window, burn, token mix and spend by model.
struct CardView: View {
    @Environment(Store.self) private var store
    let agent: Agent
    let now: Double

    private var stats: AgentStats { store.snapshot.agents[agent] ?? AgentStats(agent: agent) }
    private var standing: Standing { store.advice.standings[agent] ?? Standing(agent: agent) }
    private var tint: Color { Palette.color(agent) }

    var body: some View {
        let live = standing.plan?.live(now: now)
        VStack(alignment: .leading, spacing: 9) {
            title(live)
            todo
            headline(live)
            if let plan = standing.plan, let live {
                BurndownView(agent: agent, plan: plan, live: live, samples: store.history.samples(agent, plan.name), now: now)
                    .frame(height: ui(70))
                instruction(live)
            }
            windows
            if stats.total > 0 {
                burn
                mix
                models
            } else {
                Text("nothing burned in the last \(spanWords(store.snapshot.windowMs))")
                    .font(.system(size: ui(11))).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: Palette.card), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: Palette.cardEdge)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(glowColor(live), lineWidth: glowColor(live) == .clear ? 0 : 1.5))
        .overlay(alignment: .top) { Rectangle().fill(tint).frame(height: 2).clipShape(RoundedRectangle(cornerRadius: 1)).padding(.horizontal, 10) }
    }

    // MARK: Sections

    private func title(_ live: PaceLive?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                Text(agent.title).font(.system(size: ui(14), weight: .heavy, design: .rounded)).foregroundStyle(tint)
                if let plan = stats.limits.plan { Text("\(plan.uppercased()) PLAN").font(.system(size: ui(10), weight: .semibold)).foregroundStyle(.secondary) }
                Spacer()
                if let live { Pill(text: verdict(live), color: verdictColor(live)) }
            }
            if store.showAccounts, let account = stats.account {
                Text(account).font(.system(size: ui(10.5))).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if let change = stats.limits.planChange {
                Text("\(change.words) \(dayTime(change.atMs, now: now))")
                    .font(.system(size: ui(10.5), weight: .semibold))
                    .foregroundStyle(change.direction == .down ? Color(nsColor: Palette.warn) : tint)
            }
        }
    }

    private var todo: some View {
        var st = standing
        st.live = st.plan?.live(now: now)
        let line = todoLine(st, now: now)
        return VStack(alignment: .leading, spacing: 1) {
            Text(line.headline).font(.system(size: ui(13), weight: .bold, design: .monospaced)).foregroundStyle(Palette.tone(line.tone))
            Text(line.detail).font(.system(size: ui(10.5))).foregroundStyle(.secondary).lineLimit(2)
            if let status = stats.limits.status {
                Text(status).font(.system(size: ui(10.5), weight: .semibold)).foregroundStyle(Color(nsColor: Palette.bad))
            }
        }
    }

    @ViewBuilder
    private func headline(_ live: PaceLive?) -> some View {
        let budget = store.headline == .budget && live != nil
        Button {
            store.headline = store.headline == .budget ? .tokens : .budget
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if budget, let live {
                    Text("\(Int((live.used * 100).rounded()))%").font(.system(size: ui(30), weight: .heavy, design: .rounded))
                    Text("of the \(standing.plan?.name.lowercased() ?? "plan") plan used · \(Int((live.elapsed * 100).rounded()))% of the clock gone")
                        .font(.system(size: ui(11))).foregroundStyle(.secondary)
                } else {
                    Text(tokenWords(stats.total)).font(.system(size: ui(30), weight: .heavy, design: .rounded))
                    Text("tokens · last \(spanWords(store.snapshot.windowMs)) · \(stats.turns) turns · \(stats.sessions) sessions")
                        .font(.system(size: ui(11))).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to flip between budget and tokens")
    }

    @ViewBuilder
    private func instruction(_ live: PaceLive) -> some View {
        let hoursLeft = live.leftMs / hourMs
        let perHour = hoursLeft > 0 ? (1 - live.used) / hoursLeft * 100 : 0
        let rate = projectedRate(live)
        VStack(alignment: .leading, spacing: 2) {
            if !live.spent {
                Text(String(format: "Spend up to %.1f%% an hour and it lasts to the reset", perHour))
            }
            if rate > 0 {
                let dry = now + (1 - live.used) / rate
                if dry < live.resetsMs {
                    Text("At this rate it runs dry \(dayTime(dry, now: now)), \(spanWords(live.resetsMs - dry)) before the reset")
                        .foregroundStyle(Color(nsColor: Palette.warn))
                }
            }
        }
        .font(.system(size: ui(11)))
    }

    @ViewBuilder
    private var windows: some View {
        let rows = stats.limits.windows.filter { w in
            w.kind != .session || store.showSessionWindows || standing.heat.hot
        }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                SectionLabel("WINDOWS")
                ForEach(rows) { w in WindowRow(window: w, agent: agent, now: now, heat: w.kind == .session ? standing.heat : nil) }
            }
        }
    }

    private var burn: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("BURN")
            HStack(spacing: 14) {
                Metric(label: "NOW", value: "\(tokenWords(Int(stats.perMin5m)))/min")
                Metric(label: "1 HOUR", value: "\(tokenWords(Int(stats.perMin1h)))/min")
                Metric(label: spanWords(store.snapshot.windowMs).uppercased(), value: "\(tokenWords(Int(stats.perMinWindow)))/min")
            }
            BucketBars(buckets: stats.buckets, agent: agent, ceiling: store.lanes.compactMap { store.snapshot.agents[$0]?.peakBucket }.max() ?? 0)
                .frame(height: ui(26))
        }
    }

    private var mix: some View {
        let s = stats.split
        let taken = s.input + s.cacheWrite + s.cacheRead
        let readShare = taken > 0 ? Double(s.cacheRead) / Double(taken) * 100 : 0
        return VStack(alignment: .leading, spacing: 3) {
            SectionLabel("TOKEN MIX")
            HStack(spacing: 14) {
                Metric(label: "INPUT", value: tokenWords(s.input))
                Metric(label: "CACHE WRITE", value: tokenWords(s.cacheWrite))
                Metric(label: "OUTPUT", value: tokenWords(s.output))
            }
            // Grok leaves no token ledger: its figure is the rise of each prompt's context.
            Text(agent == .grok ? "estimated from each prompt's context growth; Grok logs no per-turn usage"
                 : String(format: "cache reads %@ · %.0f%% of everything the model took in", tokenWords(s.cacheRead), readShare))
                .font(.system(size: ui(10.5))).foregroundStyle(.secondary)
        }
    }

    private var models: some View {
        let list = stats.byModel
        let shown = list.prefix(5)
        return VStack(alignment: .leading, spacing: 3) {
            SectionLabel("BY MODEL")
            ForEach(Array(shown)) { m in
                let share = stats.total > 0 ? Double(m.tokens) / Double(stats.total) : 0
                HStack(spacing: 6) {
                    Text(m.model).font(.system(size: ui(11), design: .monospaced)).lineLimit(1).frame(width: ui(140), alignment: .leading)
                    GeometryReader { g in
                        Capsule().fill(tint.opacity(0.75)).frame(width: max(2, g.size.width * share))
                    }
                    .frame(height: 5)
                    Text(tokenWords(m.tokens)).font(.system(size: ui(11), design: .monospaced)).frame(width: ui(48), alignment: .trailing)
                }
            }
            if list.count > shown.count {
                Text("+ \(list.count - shown.count) more").font(.system(size: ui(10.5))).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Helpers

    private func verdict(_ live: PaceLive) -> String { live.verdict }

    private func verdictColor(_ live: PaceLive) -> Color {
        switch live.verdict {
        case "ON TRACK": return Color(nsColor: Palette.good)
        case "AT PACE": return .secondary
        case "OVER": return Color(nsColor: Palette.warn)
        default: return Color(nsColor: Palette.bad)
        }
    }

    /// The plan's measured climb per ms: from the recorded samples when there
    /// are enough, otherwise the average since the window opened.
    private func projectedRate(_ live: PaceLive) -> Double {
        guard let plan = standing.plan else { return 0 }
        // A burst of a few minutes is not a rate to predict a week from.
        let r = store.history.rate(agent, plan.name, now: now, lookbackMs: 6 * hourMs, minSpanMs: hourMs)
        if r > 0 { return r }
        // The average since the window opened only means something once a
        // tenth of the window has gone; before that one busy hour is the week.
        let elapsedMs = live.elapsed * live.windowMs
        return live.elapsed >= 0.10 ? live.used / elapsedMs : 0
    }

    /// A card lights up for one reason, chosen in SETUP.
    private func glowColor(_ live: PaceLive?) -> Color {
        switch store.glow {
        case .none: return .clear
        case .burning: return stats.perMin5m > 0 ? tint.opacity(0.9) : .clear
        case .spent: return live?.spent == true ? Color(nsColor: Palette.bad) : .clear
        case .overPace:
            guard let live, live.over else { return .clear }
            return Color(nsColor: live.spent || live.verdict == "WAY OVER" ? Palette.bad : Palette.warn)
        }
    }
}

// MARK: - Pieces

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: ui(9.5), weight: .bold)).kerning(1).foregroundStyle(.secondary)
    }
}

struct Pill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.system(size: ui(10), weight: .heavy)).kerning(0.6)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

struct Metric: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: ui(9), weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: ui(12), weight: .semibold, design: .monospaced))
        }
    }
}

/// A quota window: gauge, a tick where an even spend would be, and its reset.
struct WindowRow: View {
    let window: LimitReading
    let agent: Agent
    let now: Double
    let heat: SessionHeat?

    var body: some View {
        let live = window.live(now: now)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(window.name).font(.system(size: ui(11), weight: .semibold))
                Spacer()
                if window.rolledOver(now: now) {
                    Text("rolled over").font(.system(size: ui(11))).foregroundStyle(.secondary)
                } else if let p = window.percent {
                    Text("\(Int((p * 100).rounded()))%").font(.system(size: ui(11), weight: .semibold, design: .monospaced))
                } else {
                    Text("--").font(.system(size: ui(11))).foregroundStyle(.secondary)
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    if let live {
                        Capsule().fill(fill(live)).frame(width: max(2, g.size.width * live.used))
                        Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 1.5, height: 9)
                            .offset(x: g.size.width * live.elapsed - 0.75)
                    }
                }
            }
            .frame(height: 6)
            Text(caption(live)).font(.system(size: ui(10))).foregroundStyle(heat?.hot == true ? Color(nsColor: Palette.warn) : .secondary)
        }
    }

    private func fill(_ live: PaceLive) -> Color {
        if live.spent { return Color(nsColor: Palette.bad) }
        if live.over { return Color(nsColor: Palette.warn) }
        return Palette.color(agent)
    }

    private func caption(_ live: PaceLive?) -> String {
        guard let reset = window.resetsMs else { return "reset unknown" }
        if window.rolledOver(now: now) { return "reset \(dayTime(reset, now: now)) · waiting for a fresh reading" }
        var parts: [String] = []
        if let heat, heat.hot {
            parts.append(heat.spent ? "SPENT" : "runs out \(dayTime(heat.dryAt, now: now))")
        }
        parts.append("resets \(dayTime(reset, now: now)) · in \(clockSpan(reset - now))")
        if now - window.measuredMs > 30 * 60_000 { parts.append("as of \(dayTime(window.measuredMs, now: now))") }
        return parts.joined(separator: " · ")
    }
}

struct BucketBars: View {
    let buckets: [Int]
    let agent: Agent
    let ceiling: Int

    var body: some View {
        GeometryReader { g in
            let n = max(1, buckets.count)
            let w = g.size.width / CGFloat(n)
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(buckets.enumerated()), id: \.offset) { _, v in
                    let t = heatLevel(v, ceiling: ceiling)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(v == 0 ? Color.primary.opacity(0.08) : Color(nsColor: Palette.heat(t, agent: agent)))
                        .frame(width: max(1, w - 2), height: max(2, g.size.height * (v == 0 ? 0.08 : t)))
                        .frame(width: w)
                }
            }
        }
    }
}

/// The dashed diagonal is an even spend; the solid line is what was measured;
/// a dashed projection carries the current rate to the reset or to empty.
struct BurndownView: View {
    let agent: Agent
    let plan: LimitReading
    let live: PaceLive
    let samples: [PaceHistory.Sample]
    let now: Double

    var body: some View {
        Canvas { ctx, size in
            let start = live.resetsMs - live.windowMs
            func pt(_ t: Double, _ p: Double) -> CGPoint {
                CGPoint(x: size.width * CGFloat((t - start) / live.windowMs),
                        y: size.height * CGFloat(1 - min(1, max(0, p))))
            }
            let frame = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4)
            ctx.fill(frame, with: .color(.primary.opacity(0.04)))

            var even = Path(); even.move(to: pt(start, 0)); even.addLine(to: pt(live.resetsMs, 1))
            ctx.stroke(even, with: .color(.primary.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            let nowX = pt(now, 0).x
            var nowLine = Path(); nowLine.move(to: CGPoint(x: nowX, y: 0)); nowLine.addLine(to: CGPoint(x: nowX, y: size.height))
            ctx.stroke(nowLine, with: .color(.primary.opacity(0.2)), lineWidth: 1)

            let color = Palette.color(agent)
            let inWindow = samples.filter { $0.ts >= start }
            var actual = Path()
            if let first = inWindow.first {
                actual.move(to: pt(first.ts, first.percent))
                for s in inWindow.dropFirst() { actual.addLine(to: pt(s.ts, s.percent)) }
                actual.addLine(to: pt(now, live.used))
            } else {
                actual.move(to: pt(now, live.used))
            }
            ctx.stroke(actual, with: .color(color), lineWidth: 2)
            let dot = CGRect(x: pt(now, live.used).x - 3, y: pt(now, live.used).y - 3, width: 6, height: 6)
            ctx.fill(Path(ellipseIn: dot), with: .color(color))

            // Projection at the average rate since the window opened.
            let elapsedMs = now - start
            if live.elapsed >= 0.10, live.used > 0, !live.spent {
                let rate = live.used / elapsedMs
                let dry = now + (1 - live.used) / rate
                let end = min(dry, live.resetsMs)
                var proj = Path(); proj.move(to: pt(now, live.used)); proj.addLine(to: pt(end, live.used + rate * (end - now)))
                ctx.stroke(proj, with: .color(color.opacity(0.6)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
        }
        .overlay(alignment: .topLeading) {
            Text(samples.count < 2 ? "\(plan.name.uppercased()) · history fills in as Cinder Bar runs" : plan.name.uppercased())
                .font(.system(size: ui(9), weight: .semibold)).foregroundStyle(.secondary).padding(4)
        }
    }
}
