import SwiftUI
import CinderBarCore

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
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(store.lanes) { agent in
                                    CardView(agent: agent, now: now)
                                        .frame(width: cardWidth)
                                }
                            }
                        }
                    }
                }
            }
            footer
        }
        // A fixed width, so long banner lines wrap instead of widening the panel.
        .frame(width: contentWidth, alignment: .leading)
        .padding(14)
        // Opaque: the popover's translucency let the desktop wash the colours out.
        .background(Color(nsColor: Palette.panel))
        .preferredColorScheme(store.theme == .dark ? .dark : store.theme == .light ? .light : nil)
        .fixedSize()
    }

    private var contentWidth: CGFloat {
        if store.showingSetup { return ui(245) * 3 + 24 }
        let n = CGFloat(max(1, store.lanes.count))
        return max(cardWidth, n * cardWidth + (n - 1) * 12)
    }

    private var header: some View {
        let lanes = store.lanes.compactMap { store.snapshot.agents[$0] }
        let total = lanes.reduce(0) { $0 + $1.total }
        let turns = lanes.reduce(0) { $0 + $1.turns }
        let sessions = lanes.reduce(0) { $0 + $1.sessions }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("CINDER BAR").font(.system(size: ui(13), weight: .heavy, design: .rounded)).kerning(1.5)
            Text("\(tokenWords(total)) tokens · \(turns) turns · \(sessions) sessions · last \(spanWords(store.snapshot.windowMs))")
                .font(.system(size: ui(11), design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(store.showingSetup ? "DONE" : "SETUP") { store.showingSetup.toggle() }
                .buttonStyle(.borderless).font(.system(size: ui(11), weight: .semibold))
            Button { store.panelOpened(); store.refreshLimits(force: true) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).keyboardShortcut("r", modifiers: [])
                .help("Refresh now (R)")
            Button { store.quit() } label: { Image(systemName: "power") }
                .buttonStyle(.borderless).help("Quit Cinder Bar")
        }
    }

    private func chipRow(_ c: Chip) -> some View {
        HStack {
            Text(c.text).font(.system(size: ui(11), weight: .bold, design: .monospaced))
                .foregroundStyle(Color(nsColor: c.stage >= 4 ? Palette.bad : Palette.warn))
            Spacer()
            Button("Dismiss") { store.dismissChip() }.buttonStyle(.borderless).font(.system(size: ui(11)))
                .help("Hide until it gets worse or the window rolls over")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No lanes to show").font(.system(size: ui(13), weight: .semibold))
            Text("Cinder Bar draws a lane for each AI it finds transcripts for: ~/.claude/projects, ~/.codex/sessions and ~/.grok/sessions, plus Kimi turns run through Claude Code or a KIMI_API_KEY. Tick them in SETUP.")
                .font(.system(size: ui(12))).foregroundStyle(.secondary)
        }
        .frame(width: cardWidth, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Text("Cinder Bar by Simone Merli · a Mac port of Burn Bar by nixfred")
            Spacer()
            if store.snapshot.takenMs > 0 {
                Text("scan \(Int(store.snapshot.scanMs)) ms · \(dayTime(store.snapshot.takenMs, now: store.snapshot.takenMs))")
            }
        }
        .font(.system(size: ui(10)))
        .foregroundStyle(.secondary)
    }
}

struct BannerView: View {
    let banner: Banner

    var body: some View {
        let tint: Color = banner.pick.map { Palette.color($0) } ?? .secondary
        VStack(alignment: .leading, spacing: 3) {
            Text(banner.urgent ? "\(banner.headline): use it or lose it" : banner.headline)
                .font(.system(size: ui(15), weight: .heavy, design: .rounded))
                .foregroundStyle(tint)
            Text(banner.detail)
                .font(.system(size: ui(11)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.35)))
    }
}
