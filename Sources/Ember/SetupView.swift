import SwiftUI
import EmberCore

/// Every option in one place. Each row writes through to UserDefaults.
struct SetupView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("SUBSCRIPTIONS")
                Toggle("Claude", isOn: $store.claudeLane)
                note(for: .claude)
                Toggle("Codex", isOn: $store.codexLane)
                note(for: .codex)
                Divider()
                Toggle("Read Claude limits from the Claude Code sign-in", isOn: $store.claudeLimits)
                Text("Reads Claude Code's token from the login keychain and asks api.anthropic.com for your plan usage, as Claude Code's /usage does. Never stored, never refreshed.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 250, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("STRIP")
                Picker("Window", selection: $store.windowMinutes) {
                    ForEach([60, 180, 360, 720, 1440], id: \.self) { Text(spanWords(Double($0) * 60_000)).tag($0) }
                }
                Picker("Cells per lane", selection: $store.buckets) {
                    ForEach([8, 12, 18, 24], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Refresh", selection: $store.refreshSec) {
                    ForEach([5, 10, 30, 60], id: \.self) { Text("\($0)s").tag($0) }
                }
                Picker("Limits refresh", selection: $store.limitsRefreshSec) {
                    ForEach([120, 300, 600, 1800], id: \.self) { Text(spanWords(Double($0) * 1000)).tag($0) }
                }
                Toggle("Name the sub to use next on the strip", isOn: $store.adviceChip)
            }
            .frame(width: 230, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("CARDS")
                Picker("Headline", selection: $store.headline) {
                    Text("Budget").tag(Headline.budget)
                    Text("Tokens").tag(Headline.tokens)
                }
                Picker("Glow when", selection: $store.glow) {
                    Text("Over pace").tag(GlowReason.overPace)
                    Text("Burning now").tag(GlowReason.burning)
                    Text("Budget spent").tag(GlowReason.spent)
                    Text("Never").tag(GlowReason.none)
                }
                Toggle("Show 5-hour session windows", isOn: $store.showSessionWindows)
                Toggle("Launch at login", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                if let e = store.loginError {
                    Text(e).font(.system(size: 10)).foregroundStyle(Color(nsColor: Palette.bad)).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                SectionLabel("ABOUT")
                Text("Ember is a macOS port of Burn Bar, the Omarchy bar plugin by nixfred. MIT licensed.")
                    .font(.system(size: 10.5)).fixedSize(horizontal: false, vertical: true)
                Link("github.com/nixfred/burnbar", destination: URL(string: "https://github.com/nixfred/burnbar")!)
                    .font(.system(size: 10.5))
            }
            .frame(width: 230, alignment: .leading)
        }
        .font(.system(size: 12))
        .controlSize(.small)
    }

    @ViewBuilder
    private func note(for agent: Agent) -> some View {
        let present = store.snapshot.agents[agent]?.present ?? false
        let line: String = {
            guard present else { return "no transcripts on this Mac" }
            guard let st = store.advice.standings[agent] else { return "off" }
            return todoLine(st, now: Date().timeIntervalSince1970 * 1000).headline.capitalized
        }()
        Text(line).font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.leading, 20)
    }
}
