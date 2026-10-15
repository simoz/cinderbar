import SwiftUI
import CinderBarCore

/// Every option in one place, as three cards in the cockpit's own style.
/// Each row writes through to UserDefaults, so it survives a restart.
struct SetupView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 12) {
                SetupCard(title: "SUBSCRIPTIONS", icon: "flame") {
                    laneRow(.claude, isOn: $store.claudeLane)
                    RowDivider()
                    laneRow(.codex, isOn: $store.codexLane)
                    RowDivider()
                    laneRow(.grok, isOn: $store.grokLane)
                    RowDivider()
                    SwitchRow(title: "Account names", isOn: $store.showAccounts,
                              detail: "Each card names the login it reads. Turn off for a screen share.")
                }
                SetupCard(title: "CLAUDE LIMITS", icon: "gauge.with.dots.needle.50percent") {
                    SwitchRow(title: "Read plan usage", isOn: $store.claudeLimits,
                              detail: "Uses Claude Code's sign-in from the login keychain to ask api.anthropic.com for your plan usage, as /usage does. Never stored, never refreshed.")
                }
            }
            .frame(width: columnWidth)

            SetupCard(title: "STRIP", icon: "chart.bar.fill") {
                SegmentRow(title: "Window", detail: "How far back the strip reaches.", selection: $store.windowMinutes,
                           options: [60, 180, 360, 720, 1440]) { spanWords(Double($0) * 60_000) }
                RowDivider()
                SegmentRow(title: "Cells per lane", detail: nil, selection: $store.buckets,
                           options: [8, 12, 18, 24]) { "\($0)" }
                RowDivider()
                SegmentRow(title: "Refresh", detail: "Rescans the transcripts.", selection: $store.refreshSec,
                           options: [5, 10, 30, 60]) { "\($0)s" }
                RowDivider()
                SegmentRow(title: "Limits refresh", detail: "Asks the providers for fresh plan figures.", selection: $store.limitsRefreshSec,
                           options: [120, 300, 600, 1800]) { spanWords(Double($0) * 1000) }
                RowDivider()
                SwitchRow(title: "Suggest the next sub", isOn: $store.adviceChip,
                          detail: "With nothing to warn about, the chip names the subscription to use next.")
            }
            .frame(width: columnWidth)

            VStack(spacing: 12) {
                SetupCard(title: "CARDS", icon: "rectangle.split.2x1") {
                    SegmentRow(title: "Theme", detail: nil, selection: $store.theme,
                               options: PanelTheme.allCases) { $0.rawValue.capitalized }
                    RowDivider()
                    SegmentRow(title: "Headline", detail: "What each card leads with.", selection: $store.headline,
                               options: Headline.allCases) { $0 == .budget ? "Budget" : "Tokens" }
                    RowDivider()
                    SegmentRow(title: "Glow when", detail: "A card lights up for one reason.", selection: $store.glow,
                               options: GlowReason.allCases) { glowName($0) }
                    RowDivider()
                    SwitchRow(title: "5-hour session windows", isOn: $store.showSessionWindows,
                              detail: "Shown anyway when one is about to run out.")
                    RowDivider()
                    SwitchRow(title: "Launch at login", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }),
                              detail: store.loginError)
                }
                about
            }
            .frame(width: columnWidth)
        }
    }

    private var columnWidth: CGFloat { ui(245) }

    private func laneRow(_ agent: Agent, isOn: Binding<Bool>) -> some View {
        let present = store.snapshot.agents[agent]?.present ?? false
        let note: String = {
            guard present else { return "No transcripts on this Mac" }
            guard let st = store.advice.standings[agent] else { return "Hidden" }
            return todoLine(st, now: Date().timeIntervalSince1970 * 1000).headline.capitalized
        }()
        return HStack(spacing: 10) {
            Circle().fill(Palette.color(agent)).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.rawValue.capitalized).font(.system(size: ui(12), weight: .semibold))
                Text(note).font(.system(size: ui(10))).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Palette.color(agent))
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill").foregroundStyle(Color(nsColor: Palette.amber))
                Text("Cinder Bar").font(.system(size: ui(13), weight: .heavy, design: .rounded))
                Text("MIT").font(.system(size: ui(9), weight: .bold)).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            Text("Made by Simone Merli. A macOS port of Burn Bar, the Omarchy bar plugin by nixfred.")
                .font(.system(size: ui(10.5))).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Link(destination: URL(string: "https://github.com/simoz")!) {
                Label("github.com/simoz", systemImage: "person.crop.circle")
                    .font(.system(size: ui(10.5), weight: .medium))
            }
            Link(destination: URL(string: "https://github.com/nixfred/burnbar")!) {
                Label("Burn Bar · github.com/nixfred/burnbar", systemImage: "arrow.up.right.square")
                    .font(.system(size: ui(10.5), weight: .medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            LinearGradient(colors: [Color(nsColor: Palette.claude).opacity(0.16), Color(nsColor: Palette.codex).opacity(0.10)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: Palette.cardEdge)))
    }

    private func glowName(_ g: GlowReason) -> String {
        switch g {
        case .overPace: return "Over"
        case .burning: return "Burning"
        case .spent: return "Spent"
        case .none: return "Never"
        }
    }
}

// MARK: - Pieces

struct SetupCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: ui(10), weight: .semibold))
                Text(title).font(.system(size: ui(9.5), weight: .bold)).kerning(1)
            }
            .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: Palette.card), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: Palette.cardEdge)))
    }
}

struct RowDivider: View {
    var body: some View { Rectangle().fill(Color(nsColor: Palette.cardEdge)).frame(height: 1) }
}

struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: ui(12), weight: .medium))
                Spacer()
                Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            if let detail {
                Text(detail).font(.system(size: ui(10))).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A title, an optional note, and a row of chips with the selected one filled.
struct SegmentRow<Value: Hashable>: View {
    let title: String
    let detail: String?
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: ui(12), weight: .medium))
            HStack(spacing: 4) {
                ForEach(options, id: \.self) { v in
                    let on = v == selection
                    Button { selection = v } label: {
                        Text(label(v))
                            .font(.system(size: ui(10.5), weight: on ? .bold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .foregroundStyle(on ? Color(nsColor: Palette.panel) : Color.primary.opacity(0.8))
                            .background(on ? Color(nsColor: Palette.amber) : Color.primary.opacity(0.07),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if let detail {
                Text(detail).font(.system(size: ui(10))).foregroundStyle(.secondary)
            }
        }
    }
}
