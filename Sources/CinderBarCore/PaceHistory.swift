import Foundation

/// Every measured percentage of every quota window, kept for the window it
/// belongs to. Providers only report "used now", so this is what the burndown
/// line and the session window's measured rate are drawn from.
public struct PaceHistory: Codable, Equatable, Sendable {
    public struct Sample: Codable, Equatable, Sendable {
        public var ts: Double
        public var percent: Double
    }
    public struct Track: Codable, Equatable, Sendable {
        public var resetsMs: Double
        public var windowMs: Double
        public var samples: [Sample] = []
    }

    public var tracks: [String: Track] = [:]
    public init() {}

    static func key(_ agent: Agent, _ name: String) -> String { "\(agent.rawValue)/\(name)" }

    public mutating func record(_ agent: Agent, _ limits: AgentLimits) {
        for w in limits.windows {
            guard let p = w.percent, let reset = w.resetsMs, let span = w.windowMs else { continue }
            let k = Self.key(agent, w.name)
            // A reset that moved by more than a few minutes is a new window.
            var t = tracks[k] ?? Track(resetsMs: reset, windowMs: span)
            if abs(t.resetsMs - reset) > 10 * 60_000 { t = Track(resetsMs: reset, windowMs: span) }
            t.resetsMs = reset
            if let last = t.samples.last {
                if last.ts >= w.measuredMs { continue }
                // Unchanged figures only need their first and latest sample.
                if last.percent == p, t.samples.count >= 2, t.samples[t.samples.count - 2].percent == p {
                    t.samples[t.samples.count - 1].ts = w.measuredMs
                    tracks[k] = t
                    continue
                }
            }
            t.samples.append(Sample(ts: w.measuredMs, percent: p))
            if t.samples.count > 2000 { t.samples.removeFirst(t.samples.count - 2000) }
            tracks[k] = t
        }
    }

    public func samples(_ agent: Agent, _ name: String) -> [Sample] {
        tracks[Self.key(agent, name)]?.samples ?? []
    }

    /// The percentage's climb per millisecond over the last `lookbackMs`,
    /// or 0 when there is not enough to say.
    public func rate(_ agent: Agent, _ name: String, now: Double, lookbackMs: Double = hourMs,
                     minSpanMs: Double = 5 * 60_000) -> Double {
        let s = samples(agent, name).filter { $0.ts >= now - lookbackMs }
        guard let a = s.first, let b = s.last, b.ts - a.ts >= minSpanMs, b.percent > a.percent else { return 0 }
        return (b.percent - a.percent) / (b.ts - a.ts)
    }

    public mutating func prune(now: Double) {
        tracks = tracks.filter { $0.value.resetsMs > now - dayMs }
    }
}
