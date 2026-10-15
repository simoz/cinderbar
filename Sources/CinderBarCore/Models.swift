import Foundation

public enum Agent: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude, codex, grok, kimi
    public var id: String { rawValue }
    public var title: String { rawValue.uppercased() }
}

public struct TokenSplit: Codable, Equatable, Sendable {
    public var input = 0       // fresh input
    public var cacheWrite = 0
    public var output = 0
    public var cacheRead = 0
    public init(input: Int = 0, cacheWrite: Int = 0, output: Int = 0, cacheRead: Int = 0) {
        self.input = input; self.cacheWrite = cacheWrite; self.output = output; self.cacheRead = cacheRead
    }
    /// What the heat map counts: fresh input + cache writes + output. Cache
    /// reads are the cheap path that would swamp the graph; they ride along.
    public var heat: Int { input + cacheWrite + output }
    public static func + (a: TokenSplit, b: TokenSplit) -> TokenSplit {
        TokenSplit(input: a.input + b.input, cacheWrite: a.cacheWrite + b.cacheWrite,
                   output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead)
    }
}

public struct UsagePoint: Codable, Equatable, Sendable {
    public var ts: Double          // ms since epoch
    public var split: TokenSplit
    public var model: String
    public var session: String
    /// Dedupe key (Claude's message.id); nil when every point is distinct.
    public var key: String?
}

/// A plan change the provider reported inside the current window. The figures
/// before it were measured against another pool, so they are not compared with
/// the ones after it.
public struct PlanChange: Codable, Equatable, Sendable {
    public enum Direction: String, Codable, Sendable { case up, down, unknown }
    public var from: String
    public var to: String
    public var atMs: Double
    public var direction: Direction
    public init(from: String, to: String, atMs: Double, direction: Direction) {
        self.from = from; self.to = to; self.atMs = atMs; self.direction = direction
    }
    /// "upgraded to Heavy", "downgraded to Plus", "plan now Pro".
    public var words: String {
        switch direction {
        case .up: return "upgraded to \(to)"
        case .down: return "downgraded to \(to)"
        case .unknown: return "plan now \(to)"
        }
    }
}

public enum LimitKind: String, Codable, Sendable { case session, plan, extra }

/// One quota window as the provider reported it.
public struct LimitReading: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var kind: LimitKind
    public var percent: Double?     // 0...1, nil when it could not be read
    public var resetsMs: Double?
    public var windowMs: Double?
    public var measuredMs: Double
    public var id: String { name }

    public init(name: String, kind: LimitKind, percent: Double?, resetsMs: Double?, windowMs: Double?, measuredMs: Double) {
        self.name = name; self.kind = kind; self.percent = percent
        self.resetsMs = resetsMs; self.windowMs = windowMs; self.measuredMs = measuredMs
    }

    /// A window whose reset has passed reads "rolled over"; its figure is withheld.
    public func rolledOver(now: Double) -> Bool { (resetsMs ?? .infinity) <= now }

    public func live(now: Double) -> PaceLive? {
        rolledOver(now: now) ? nil : paceLive(percent, resetsMs: resetsMs, windowMs: windowMs, nowMs: now)
    }
}

public struct AgentLimits: Codable, Equatable, Sendable {
    public var windows: [LimitReading] = []
    public var status: String?          // "Sign-in expired", an error, or nil
    public var plan: String?
    public var planChange: PlanChange?
    public init(windows: [LimitReading] = [], status: String? = nil, plan: String? = nil, planChange: PlanChange? = nil) {
        self.windows = windows; self.status = status; self.plan = plan; self.planChange = planChange
    }
    public var planWindow: LimitReading? { windows.first { $0.kind == .plan } }
    public var sessionWindow: LimitReading? { windows.first { $0.kind == .session } }
}

public struct ModelShare: Equatable, Sendable, Identifiable {
    public var model: String
    public var tokens: Int
    public var id: String { model }
}

public struct AgentStats: Equatable, Sendable {
    public var agent: Agent
    public var present = false          // transcripts exist on this machine
    public var buckets: [Int] = []      // oldest first, newest last
    public var bucketStart: Double = 0
    public var bucketMs: Double = 0
    public var total = 0                // heat tokens in the exact trailing window
    public var split = TokenSplit()
    public var turns = 0
    public var sessions = 0
    public var perMin5m: Double = 0
    public var perMin1h: Double = 0
    public var perMinWindow: Double = 0
    public var byModel: [ModelShare] = []
    public var firstMs: Double = 0
    public var lastMs: Double = 0
    public var peakBucket = 0
    public var limits = AgentLimits()
    /// Newest write to any of the agent's files, however old. For a snapshot
    /// quota (Grok) it says whether the agent was used after the figure was taken.
    public var lastUseMs: Double = 0
    /// Who the agent is signed in as: one display field, never a token.
    public var account: String?
    public init(agent: Agent) { self.agent = agent }
}

public struct Snapshot: Equatable, Sendable {
    public var takenMs: Double
    public var windowMs: Double
    public var agents: [Agent: AgentStats]
    public var scanMs: Double = 0
    public init(takenMs: Double, windowMs: Double, agents: [Agent: AgentStats]) {
        self.takenMs = takenMs; self.windowMs = windowMs; self.agents = agents
    }
    public static let empty = Snapshot(takenMs: 0, windowMs: 6 * hourMs, agents: [:])
}
