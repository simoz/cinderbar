import SwiftUI
import EmberCore

/// The click-to-open cockpit: a guidance banner, then one card per subscription.
struct CockpitView: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if store.showingSetup {
                SetupView()
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let now = ctx.date.timeIntervalSince1970 * 1000
                    VStack(alignment: .leading, spacing: 10) {
                        if let c = store.chip, c.warning { chipRow(c) }
                        if let b = banner(store.advice, burning: store.burning, now: now) { BannerView(banner: b) }
                        if store.lanes.isEmpty {
                            emptyState
                        } else {
                            HStack(alignment: .top, spacing: 10) {
                                ForEach(store.lanes) { agent in
                                    CardView(agent: agent, now: now)
                                        .frame(width: 330)
                                }
                            }
                        }
                    }
                }
            }
            footer
        }
        .padding(14)
        .frame(minWidth: 360)
        .onAppear { store.panelOpened() }
    }

    private var header: some View {
        let lanes = store.lanes.compactMap { store.snapshot.agents[$0] }
        let total = lanes.reduce(0) { $0 + $1.total }
        let turns = lanes.reduce(0) { $0 + $1.turns }
        let sessions = lanes.reduce(0) { $0 + $1.sessions }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("EMBER").font(.system(size: 13, weight: .heavy, design: .rounded)).kerning(1.5)
            Text("\(tokenWords(total)) tokens · \(turns) turns · \(sessions) sessions · last \(spanWords(store.snapshot.windowMs))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(store.showingSetup ? "DONE" : "SETUP") { store.showingSetup.toggle() }
                .buttonStyle(.borderless).font(.system(size: 11, weight: .semibold))
            Button { store.panelOpened(); store.refreshLimits(force: true) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).keyboardShortcut("r", modifiers: [])
                .help("Refresh now (R)")
            Button { store.quit() } label: { Image(systemName: "power") }
                .buttonStyle(.borderless).help("Quit Ember")
        }
    }

    private func chipRow(_ c: Chip) -> some View {
        HStack {
            Text(c.text).font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(nsColor: c.stage >= 4 ? Palette.bad : Palette.warn))
            Spacer()
            Button("Dismiss") { store.dismissChip() }.buttonStyle(.borderless).font(.system(size: 11))
                .help("Hide until it gets worse or the window rolls over")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No lanes to show").font(.headline)
            Text("Ember draws a lane for each AI it finds transcripts for: ~/.claude/projects and ~/.codex/sessions. Tick them in SETUP.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(width: 330, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Text("Ember · a Mac port of Burn Bar by nixfred")
            Spacer()
            if store.snapshot.takenMs > 0 {
                Text("scan \(Int(store.snapshot.scanMs)) ms · \(dayTime(store.snapshot.takenMs, now: store.snapshot.takenMs))")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
    }
}

struct BannerView: View {
    let banner: Banner

    var body: some View {
        let tint: Color = banner.pick.map { Palette.color($0) } ?? .secondary
        VStack(alignment: .leading, spacing: 3) {
            Text(banner.urgent ? "\(banner.headline): use it or lose it" : banner.headline)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(tint)
            Text(banner.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.35)))
    }
}
