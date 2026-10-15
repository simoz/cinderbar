import Foundation

/// What one line of a transcript contributes.
public struct LineYield {
    public var points: [UsagePoint] = []
    public var limits: AgentLimits?
}

/// Per-file state an extractor carries between appended reads.
public struct ExtractState: Codable, Equatable, Sendable {
    public var lastTotal: TokenSplit?   // Codex's cumulative counter
    public var model = ""
    /// Grok: each prompt's context-size range so far, keyed by promptId.
    public var prompts: [String: PromptSpan]?
    /// Grok's billing log: the plan named last, and the change that led to it.
    public var tier: String?
    public var planChange: PlanChange?
}

public struct PromptSpan: Codable, Equatable, Sendable {
    public var ts: Double
    public var min: Int
    public var max: Int
}

public typealias Extractor = (_ line: [String: Any], _ state: inout ExtractState, _ session: String) -> LineYield

struct FileEntry: Codable {
    var size: UInt64
    var mtime: Double
    var offset: UInt64
    var tail: Data              // the 48 bytes just before `offset`
    var points: [UsagePoint]
    var state: ExtractState
    var limits: AgentLimits?
}

/// Incremental transcript reader. A file whose size and mtime are unchanged
/// replays its cached contribution; a file that merely grew is read from the
/// previous offset, but only if the 48 bytes before that offset still read the
/// same, so a longer rewrite is not mistaken for an append.
public final class Scanner {
    static let tailLength = 48
    var entries: [String: FileEntry] = [:]
    /// Points older than this are dropped from the cache; nothing reads them.
    public var keepMs: Double

    public init(keepMs: Double = dayMs) { self.keepMs = keepMs }

    public struct FileResult {
        public var points: [UsagePoint]
        public var limits: AgentLimits?
    }

    /// `session` names the points; by default it is the file name without `.jsonl`.
    public func scan(path: String, needles: [Data], extract: Extractor, now: Double, session: String? = nil) -> FileResult? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let mdate = attrs[.modificationDate] as? Date else {
            entries[path] = nil
            return nil
        }
        let mtime = mdate.timeIntervalSince1970 * 1000
        var entry = entries[path]
        if let e = entry, e.size == size, e.mtime == mtime {
            return FileResult(points: prune(e.points, now: now), limits: e.limits)
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        if let e = entry {
            var appended = size > e.offset && e.offset >= UInt64(e.tail.count)
            if appended {
                try? handle.seek(toOffset: e.offset - UInt64(e.tail.count))
                appended = (try? handle.read(upToCount: e.tail.count)) == e.tail
            }
            if !appended { entry = nil }
        }
        var e = entry ?? FileEntry(size: 0, mtime: 0, offset: 0, tail: Data(), points: [], state: ExtractState(), limits: nil)
        try? handle.seek(toOffset: e.offset)
        let data = (try? handle.readToEnd()) ?? Data()

        // Only whole lines: a line still being written is read next time.
        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            e.size = size; e.mtime = mtime
            entries[path] = e
            return FileResult(points: prune(e.points, now: now), limits: e.limits)
        }
        let session = session ?? (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
        var start = data.startIndex
        while start <= lastNewline {
            let end = data[start...lastNewline].firstIndex(of: 0x0A) ?? lastNewline
            let line = data[start..<end]
            start = end + 1
            if line.isEmpty || !needles.contains(where: { line.range(of: $0) != nil }) { continue }
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            let y = extract(obj, &e.state, session)
            e.points.append(contentsOf: y.points)
            if let l = y.limits { e.limits = l }
        }
        let consumed = UInt64(lastNewline - data.startIndex + 1)
        e.offset += consumed
        let tailStart = max(data.startIndex, lastNewline + 1 - Scanner.tailLength)
        var tail = Data(data[tailStart...lastNewline])
        if tail.count < Scanner.tailLength, e.offset >= UInt64(Scanner.tailLength) {
            try? handle.seek(toOffset: e.offset - UInt64(Scanner.tailLength))
            tail = (try? handle.read(upToCount: Scanner.tailLength)) ?? tail
        }
        e.tail = tail
        e.size = size
        e.mtime = mtime
        e.points = prune(e.points, now: now)
        entries[path] = e
        return FileResult(points: e.points, limits: e.limits)
    }

    func prune(_ points: [UsagePoint], now: Double) -> [UsagePoint] {
        let cutoff = now - keepMs
        return points.contains { $0.ts < cutoff } ? points.filter { $0.ts >= cutoff } : points
    }

    /// Forget files that were not seen in the last walk.
    public func retain(_ seen: Set<String>) {
        entries = entries.filter { seen.contains($0.key) }
    }

    // MARK: Persistence

    public func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public func load(from url: URL) {
        // A cache that does not decode is rebuilt from disk, never believed.
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: FileEntry].self, from: data) else { return }
        entries = decoded
    }
}

// MARK: - Helpers shared by the extractors

func int(_ v: Any?) -> Int {
    if let n = v as? NSNumber { return max(0, n.intValue) }
    if let s = v as? String, let n = Int(s) { return max(0, n) }
    return 0
}

func double(_ v: Any?) -> Double? {
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s) }
    return nil
}

private let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoPlain = ISO8601DateFormatter()

public func parseTimestamp(_ v: Any?) -> Double? {
    if let s = v as? String {
        if let d = isoFractional.date(from: s) ?? isoPlain.date(from: s) { return d.timeIntervalSince1970 * 1000 }
        return nil
    }
    if let n = double(v) { return n > 1e12 ? n : n * 1000 }
    return nil
}
