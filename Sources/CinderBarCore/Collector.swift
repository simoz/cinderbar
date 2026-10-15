import Foundation

public struct CollectorConfig: Sendable {
    public var windowMs: Double = 6 * hourMs
    public var buckets = 12
    public var claudeRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
    public var codexRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    public var grokHome = Grok.home
    public init() {}
}

/// Turns the raw transcripts into one Snapshot. Not thread-safe: own it from
/// a single actor.
public final class Collector {
    let scanner: Scanner
    let cacheURL: URL?
    var grokModels: [String: (mtime: Double, model: String)] = [:]
    var grokUsage: [String: (mtime: Double, size: Int, points: [UsagePoint])] = [:]

    public init(cacheURL: URL?) {
        // The longest supported strip window is 24h; nothing older is kept.
        scanner = Scanner(keepMs: dayMs)
        self.cacheURL = cacheURL
        if let url = cacheURL { scanner.load(from: url) }
    }

    public func persist() { if let url = cacheURL { scanner.save(to: url) } }

    public func collect(_ cfg: CollectorConfig, now: Double = Date().timeIntervalSince1970 * 1000) -> Snapshot {
        let started = Date()
        var seen = Set<String>()
        var agents: [Agent: AgentStats] = [:]

        // Claude: files untouched for a day cannot hold points inside any window.
        let claudeFiles = walk(cfg.claudeRoot, since: now - dayMs)
        var claudeByKey: [String: UsagePoint] = [:]
        var claudeLoose: [UsagePoint] = []
        for path in claudeFiles {
            seen.insert(path)
            guard let r = scanner.scan(path: path, needles: [Data("\"usage\"".utf8)], extract: claudeExtract, now: now) else { continue }
            for p in r.points {
                guard let k = p.key else { claudeLoose.append(p); continue }
                if let held = claudeByKey[k], held.split.heat + held.split.cacheRead >= p.split.heat + p.split.cacheRead { continue }
                claudeByKey[k] = p
            }
        }
        var claude = aggregate(.claude, points: Array(claudeByKey.values) + claudeLoose, cfg: cfg, now: now)
        claude.present = FileManager.default.fileExists(atPath: cfg.claudeRoot.path)
        agents[.claude] = claude

        // Codex: a week back, because the newest rate_limits block is the plan
        // meter even when Codex has not been used today.
        let codexFiles = walk(cfg.codexRoot, since: now - 8 * dayMs)
        var codexPoints: [UsagePoint] = []
        var codexLimits: AgentLimits?
        var newestMeasure: Double = 0
        for path in codexFiles {
            seen.insert(path)
            let needles = [Data("token_count".utf8), Data("turn_context".utf8)]
            guard let r = scanner.scan(path: path, needles: needles, extract: codexExtract, now: now) else { continue }
            codexPoints += r.points
            if let l = r.limits, let m = l.windows.map(\.measuredMs).max(), m > newestMeasure {
                newestMeasure = m
                codexLimits = l
            }
        }
        var codex = aggregate(.codex, points: codexPoints, cfg: cfg, now: now)
        codex.present = FileManager.default.fileExists(atPath: cfg.codexRoot.path)
        if let l = codexLimits { codex.limits = l }
        agents[.codex] = codex

        agents[.grok] = collectGrok(cfg, now: now, seen: &seen)

        scanner.retain(seen)
        var snap = Snapshot(takenMs: now, windowMs: cfg.windowMs, agents: agents)
        snap.scanMs = Date().timeIntervalSince(started) * 1000
        return snap
    }

    /// Grok: per-turn usage from each session's usage.json (else the burn
    /// estimated from updates.jsonl), the weekly figure and plan from the
    /// billing log, and the signed-in account.
    func collectGrok(_ cfg: CollectorConfig, now: Double, seen: inout Set<String>) -> AgentStats {
        let root = cfg.grokHome.appendingPathComponent("sessions")
        var newest: Double = 0
        let files = walk(root, since: now - dayMs, newest: &newest) { $0 == "updates.jsonl" || $0 == "usage.json" }
        var byKey: [String: UsagePoint] = [:]
        func keep(_ p: UsagePoint) {
            let k = p.key ?? "\(p.ts)"
            if let held = byKey[k], (held.ts, held.split.heat) >= (p.ts, p.split.heat) { return }
            byKey[k] = p
        }
        var seenUsage = Set<String>()
        for path in files where (path as NSString).lastPathComponent == "usage.json" {
            let dir = (path as NSString).deletingLastPathComponent
            seenUsage.insert(path)
            guard let points = readGrokUsage(path: path, session: (dir as NSString).lastPathComponent) else { continue }
            let fallback = points.contains { $0.model.isEmpty } ? grokModel(sessionDir: dir) : ""
            for var p in points {
                if p.model.isEmpty { p.model = fallback }
                keep(p)
            }
        }
        grokUsage = grokUsage.filter { seenUsage.contains($0.key) }
        for path in files where (path as NSString).lastPathComponent == "updates.jsonl" {
            let dir = (path as NSString).deletingLastPathComponent
            // A session with a ledger, even an older one, is never estimated.
            if FileManager.default.fileExists(atPath: dir + "/usage.json") { continue }
            seen.insert(path)
            let session = (dir as NSString).lastPathComponent
            guard let r = scanner.scan(path: path, needles: [Data("totalTokens".utf8)], extract: grokExtract,
                                       now: now, session: session) else { continue }
            let model = grokModel(sessionDir: dir)
            for var p in r.points {
                p.model = model
                keep(p)
            }
        }
        var grok = aggregate(.grok, points: Array(byKey.values), cfg: cfg, now: now)
        grok.lastUseMs = newest

        let log = cfg.grokHome.appendingPathComponent("logs/unified.jsonl")
        let hasLog = FileManager.default.fileExists(atPath: log.path)
        grok.present = FileManager.default.fileExists(atPath: root.path) || hasLog
        if hasLog {
            seen.insert(log.path)
            let r = scanner.scan(path: log.path, needles: [Data(Grok.billingMessage.utf8)], extract: grokBillingExtract, now: now)
            if var l = r?.limits {
                l.planChange = Grok.currentChange(l.planChange, plan: l.planWindow, now: now)
                // Say so rather than presenting last week's window as this week's.
                if l.planWindow?.rolledOver(now: now) == true { l.status = "Grok window has reset; run grok to refresh" }
                grok.limits = l
            } else {
                grok.limits = AgentLimits(status: "Grok billing data unavailable")
            }
        }
        if grok.present { grok.account = Grok.account(authURL: cfg.grokHome.appendingPathComponent("auth.json")) }
        return grok
    }

    /// A usage.json's turns, cached by mtime and size. The file is rewritten
    /// whole, so it is read whole. One caught mid-rewrite keeps the last good read.
    func readGrokUsage(path: String, session: String) -> [UsagePoint]? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.intValue, size <= 16 << 20,
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { return nil }
        if let hit = grokUsage[path], hit.mtime == mtime, hit.size == size { return hit.points }
        guard let data = FileManager.default.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return grokUsage[path]?.points }
        let points = grokUsagePoints(obj, session: session)
        grokUsage[path] = (mtime, size, points)
        return points
    }

    /// The model a Grok session ran, from its summary.json, cached by mtime.
    func grokModel(sessionDir: String) -> String {
        let path = sessionDir + "/summary.json"
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        if let hit = grokModels[path], hit.mtime == mtime { return hit.model }
        var model = "grok"
        if mtime > 0, let data = FileManager.default.contents(atPath: path),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let info = obj["info"] as? [String: Any]
            let id = (obj["current_model_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (info?["model_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (info?["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let id { model = String(id.prefix(64)) }
        }
        grokModels[path] = (mtime, model)
        return model
    }

    func walk(_ root: URL, since: Double) -> [String] {
        var newest: Double = 0
        return walk(root, since: since, newest: &newest) { ($0 as NSString).pathExtension == "jsonl" }
    }

    /// `newest` sees every matching file, even ones too old to return.
    func walk(_ root: URL, since: Double, newest: inout Double, match: (String) -> Bool) -> [String] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        // Symlinks are not followed: a loop must not hang the menu bar.
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [String] = []
        for case let url as URL in e where match(url.lastPathComponent) {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let m = v.contentModificationDate else { continue }
            let ms = m.timeIntervalSince1970 * 1000
            newest = max(newest, ms)
            if ms >= since { out.append(url.path) }
        }
        return out
    }
}

/// Two clocks. The strip uses grid-aligned buckets so cells march instead of
/// jittering (`buckets - 1` whole buckets plus the partial newest one); every
/// headline number uses the exact trailing window.
public func aggregate(_ agent: Agent, points: [UsagePoint], cfg: CollectorConfig, now: Double) -> AgentStats {
    var s = AgentStats(agent: agent)
    let n = max(1, cfg.buckets)
    let bucketMs = (cfg.windowMs / Double(n)).rounded()
    let gridNow = (now / bucketMs).rounded(.down) * bucketMs
    let gridStart = gridNow - Double(n - 1) * bucketMs
    s.buckets = Array(repeating: 0, count: n)
    s.bucketStart = gridStart
    s.bucketMs = bucketMs

    let windowStart = now - cfg.windowMs
    var sessions = Set<String>()
    var models: [String: Int] = [:]
    var sum5m = 0, sum1h = 0
    for p in points where p.ts <= now + 60_000 {
        let idx = Int(((p.ts - gridStart) / bucketMs).rounded(.down))
        if idx >= 0 && idx < n { s.buckets[idx] += p.split.heat }
        guard p.ts >= windowStart else { continue }
        s.total += p.split.heat
        s.split = s.split + p.split
        s.turns += 1
        sessions.insert(p.session)
        models[p.model, default: 0] += p.split.heat
        if p.ts >= now - 5 * 60_000 { sum5m += p.split.heat }
        if p.ts >= now - hourMs { sum1h += p.split.heat }
        s.firstMs = s.firstMs == 0 ? p.ts : min(s.firstMs, p.ts)
        s.lastMs = max(s.lastMs, p.ts)
    }
    s.sessions = sessions.count
    s.perMin5m = Double(sum5m) / 5
    s.perMin1h = Double(sum1h) / 60
    s.perMinWindow = Double(s.total) / (cfg.windowMs / 60_000)
    s.byModel = models.map { ModelShare(model: $0.key, tokens: $0.value) }
        .filter { $0.tokens > 0 }
        .sorted { $0.tokens > $1.tokens }
    s.peakBucket = s.buckets.max() ?? 0
    return s
}
