import Foundation

public struct CollectorConfig: Sendable {
    public var windowMs: Double = 6 * hourMs
    public var buckets = 12
    public var claudeRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
    public var codexRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    public init() {}
}

/// Turns the raw transcripts into one Snapshot. Not thread-safe: own it from
/// a single actor.
public final class Collector {
    let scanner: Scanner
    let cacheURL: URL?

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

        scanner.retain(seen)
        var snap = Snapshot(takenMs: now, windowMs: cfg.windowMs, agents: agents)
        snap.scanMs = Date().timeIntervalSince(started) * 1000
        return snap
    }

    func walk(_ root: URL, since: Double) -> [String] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        // Symlinks are not followed: a loop must not hang the menu bar.
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [String] = []
        for case let url as URL in e where url.pathExtension == "jsonl" {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let m = v.contentModificationDate, m.timeIntervalSince1970 * 1000 >= since else { continue }
            out.append(url.path)
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
