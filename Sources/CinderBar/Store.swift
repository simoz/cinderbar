import AppKit
import Observation
import ServiceManagement
import CinderBarCore

/// Owns the collector off the main thread.
actor CollectorBox {
    let collector: Collector
    var lastPersist = Date.distantPast

    init(cacheURL: URL) { collector = Collector(cacheURL: cacheURL) }

    func collect(_ cfg: CollectorConfig) -> Snapshot {
        let snap = collector.collect(cfg)
        if Date().timeIntervalSince(lastPersist) > 60 {
            collector.persist()
            lastPersist = Date()
        }
        return snap
    }

    func persist() { collector.persist() }
}

enum Headline: String, CaseIterable { case budget, tokens }
enum GlowReason: String, CaseIterable { case overPace, burning, spent, none }
enum PanelTheme: String, CaseIterable { case dark, light, system }

@MainActor
@Observable
final class Store {
    static let shared = Store()

    // MARK: Settings (each writes through to UserDefaults, so it survives a restart)

    @ObservationIgnored private let defaults = UserDefaults.standard

    var windowMinutes: Int { didSet { save("windowMinutes", windowMinutes); refreshSoon() } }
    var buckets: Int { didSet { save("buckets", buckets); refreshSoon() } }
    var refreshSec: Int { didSet { save("refreshSec", refreshSec) } }
    var limitsRefreshSec: Int { didSet { save("limitsRefreshSec", limitsRefreshSec) } }
    var claudeLane: Bool { didSet { save("claudeLane", claudeLane); recompute() } }
    var codexLane: Bool { didSet { save("codexLane", codexLane); recompute() } }
    var grokLane: Bool { didSet { save("grokLane", grokLane); recompute() } }
    var showAccounts: Bool { didSet { save("showAccounts", showAccounts) } }
    var claudeLimits: Bool { didSet { save("claudeLimits", claudeLimits); if claudeLimits { refreshLimits(force: true) } else { claudeReading = nil; recompute() } } }
    var headline: Headline { didSet { save("headline", headline.rawValue) } }
    var showSessionWindows: Bool { didSet { save("showSessionWindows", showSessionWindows) } }
    var adviceChip: Bool { didSet { save("adviceChip", adviceChip); recompute() } }
    var glow: GlowReason { didSet { save("glow", glow.rawValue) } }
    var theme: PanelTheme { didSet { save("theme", theme.rawValue); onThemeChange?(theme) } }

    // MARK: Live state

    var snapshot = Snapshot.empty
    var advice = Advice()
    var chip: Chip?
    var stripImage: NSImage
    var history = PaceHistory()
    var loginError: String?
    var lastLimitsFetch: Date?
    var showingSetup = false
    var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// The status item's button follows this; set by the app delegate.
    @ObservationIgnored var onStripChange: ((NSImage, String) -> Void)?
    @ObservationIgnored var onThemeChange: ((PanelTheme) -> Void)?
    @ObservationIgnored private var claudeReading: AgentLimits?
    @ObservationIgnored private var dismissed: [Agent: (stage: Int, reset: Double)] = [:]
    @ObservationIgnored private let box: CollectorBox
    @ObservationIgnored private let historyURL: URL
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var limitsTask: Task<Void, Never>?

    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CinderBar")
    }

    init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            "windowMinutes": 360, "buckets": 12, "refreshSec": 5, "limitsRefreshSec": 300,
            "claudeLane": true, "codexLane": true, "grokLane": true, "showAccounts": true, "claudeLimits": true, "headline": "budget",
            "showSessionWindows": false, "adviceChip": true, "glow": "overPace", "theme": "dark",
        ])
        windowMinutes = d.integer(forKey: "windowMinutes")
        buckets = d.integer(forKey: "buckets")
        refreshSec = d.integer(forKey: "refreshSec")
        limitsRefreshSec = d.integer(forKey: "limitsRefreshSec")
        claudeLane = d.bool(forKey: "claudeLane")
        codexLane = d.bool(forKey: "codexLane")
        grokLane = d.bool(forKey: "grokLane")
        showAccounts = d.bool(forKey: "showAccounts")
        claudeLimits = d.bool(forKey: "claudeLimits")
        headline = Headline(rawValue: d.string(forKey: "headline") ?? "") ?? .budget
        showSessionWindows = d.bool(forKey: "showSessionWindows")
        adviceChip = d.bool(forKey: "adviceChip")
        glow = GlowReason(rawValue: d.string(forKey: "glow") ?? "") ?? .overPace
        theme = PanelTheme(rawValue: d.string(forKey: "theme") ?? "") ?? .dark

        // State lives in Application Support, never beside the app.
        let dir = Store.supportDir
        // Carry the scan cache and pace history over from the app's old name.
        let legacy = dir.deletingLastPathComponent().appendingPathComponent("Ember")
        if !FileManager.default.fileExists(atPath: dir.path), FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        box = CollectorBox(cacheURL: dir.appendingPathComponent("scan-cache.json"))
        historyURL = dir.appendingPathComponent("pace-history.json")
        if let data = try? Data(contentsOf: historyURL), let h = try? JSONDecoder().decode(PaceHistory.self, from: data) {
            history = h
        }
        stripImage = StripRenderer.image(snapshot: .empty, lanes: [], standings: [:], chip: nil, fault: false)
        start()
    }

    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }

    /// Lanes that are ticked and have transcripts on this machine.
    var lanes: [Agent] {
        Agent.allCases.filter { a in
            laneOn(a) && (snapshot.agents[a]?.present ?? true)
        }
    }

    func laneOn(_ a: Agent) -> Bool {
        switch a { case .claude: return claudeLane; case .codex: return codexLane; case .grok: return grokLane }
    }

    var burning: Agent? {
        lanes.filter { (snapshot.agents[$0]?.perMin5m ?? 0) > 0 }
            .max { (snapshot.agents[$0]?.perMin5m ?? 0) < (snapshot.agents[$1]?.perMin5m ?? 0) }
    }

    // MARK: Loop

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                if let last = self.lastLimitsFetch, Date().timeIntervalSince(last) < Double(self.limitsRefreshSec) {} else {
                    self.refreshLimits(force: true)
                }
                try? await Task.sleep(for: .seconds(max(2, self.refreshSec)))
            }
        }
    }

    private func refreshSoon() { Task { await refresh() } }

    func refresh() async {
        var cfg = CollectorConfig()
        cfg.windowMs = Double(windowMinutes) * 60_000
        cfg.buckets = buckets
        var snap = await box.collect(cfg)
        if let c = claudeReading, var stats = snap.agents[.claude] {
            stats.limits = c
            snap.agents[.claude] = stats
        }
        snapshot = snap
        for a in [Agent.codex, .grok] {
            if let l = snap.agents[a]?.limits, !l.windows.isEmpty { history.record(a, l) }
        }
        recompute()
    }

    /// Opening the panel asks for fresh limits, at most once a minute.
    func panelOpened() {
        Task { await refresh() }
        refreshLimits(force: false)
    }

    func refreshLimits(force: Bool) {
        guard claudeLimits, claudeLane, limitsTask == nil else { return }
        if !force, let last = lastLimitsFetch, Date().timeIntervalSince(last) < 60 { return }
        lastLimitsFetch = Date()
        limitsTask = Task { [weak self] in
            let reading = await ClaudeLimits.fetch()
            guard let self else { return }
            self.limitsTask = nil
            // A failed probe keeps the last good figures, flagged with the reason.
            if reading.windows.isEmpty, var held = self.claudeReading, !held.windows.isEmpty {
                held.status = reading.status
                self.claudeReading = held
            } else {
                self.claudeReading = reading
                self.history.record(.claude, reading)
                self.saveHistory()
            }
            if var stats = self.snapshot.agents[.claude], let c = self.claudeReading {
                stats.limits = c
                self.snapshot.agents[.claude] = stats
            }
            self.recompute()
        }
    }

    func recompute() {
        let now = Date().timeIntervalSince1970 * 1000
        let previous = advice.guidance.pick
        advice = advise(snapshot, enabled: lanes, history: history, previous: previous, now: now)
        var c = CinderBarCore.chip(advice, enabled: lanes, showAdvice: adviceChip, now: now)
        if let cur = c, cur.warning, let d = dismissed[cur.agent],
           cur.stage <= d.stage, d.reset == (advice.standings[cur.agent]?.plan?.resetsMs ?? 0) {
            c = nil
        }
        chip = c
        stripImage = StripRenderer.image(snapshot: snapshot, lanes: lanes, standings: advice.standings,
                                         chip: chip, fault: false)
        onStripChange?(stripImage, chip?.text ?? "Cinder Bar")
    }

    /// A dismissed warning stays gone until that sub reaches a worse stage or its window rolls over.
    func dismissChip() {
        guard let c = chip, c.warning else { return }
        dismissed[c.agent] = (c.stage, advice.standings[c.agent]?.plan?.resetsMs ?? 0)
        recompute()
    }

    func saveHistory() {
        history.prune(now: Date().timeIntervalSince1970 * 1000)
        if let data = try? JSONEncoder().encode(history) { try? data.write(to: historyURL, options: .atomic) }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            // Only an app bundle can register; `swift run` cannot.
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func quit() {
        saveHistory()
        Task {
            await box.persist()
            NSApp.terminate(nil)
        }
    }
}
