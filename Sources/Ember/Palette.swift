import AppKit
import SwiftUI
import EmberCore

enum Palette {
    static let claude = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)   // Claude orange
    static let codex = NSColor(srgbRed: 0.169, green: 0.710, blue: 0.651, alpha: 1)    // Codex teal
    static let ember = NSColor(srgbRed: 0.20, green: 0.09, blue: 0.06, alpha: 1)       // cold coal
    static let amber = NSColor(srgbRed: 1.0, green: 0.71, blue: 0.20, alpha: 1)
    static let whiteHot = NSColor(srgbRed: 1.0, green: 0.97, blue: 0.90, alpha: 1)
    static let warn = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.18, alpha: 1)
    static let bad = NSColor(srgbRed: 0.94, green: 0.27, blue: 0.24, alpha: 1)
    static let good = NSColor(srgbRed: 0.40, green: 0.80, blue: 0.45, alpha: 1)

    static func ns(_ agent: Agent) -> NSColor { agent == .claude ? claude : codex }
    static func color(_ agent: Agent) -> Color { Color(nsColor: ns(agent)) }

    /// Cold ember, agent colour, amber, white-hot. Both agents converge on the
    /// same white at the top: a maxed-out burst looks equally alarming whoever caused it.
    static func heat(_ t: Double, agent: Agent) -> NSColor {
        let x = max(0, min(1, t))
        let stops: [(Double, NSColor)] = [(0, ember), (0.45, ns(agent)), (0.78, amber), (1, whiteHot)]
        for i in 1..<stops.count where x <= stops[i].0 {
            let (a, ca) = stops[i - 1], (b, cb) = stops[i]
            return ca.blended(withFraction: (x - a) / (b - a), of: cb) ?? cb
        }
        return whiteHot
    }

    static func tone(_ t: TodoLine.Tone) -> Color {
        switch t {
        case .good: return Color(nsColor: good)
        case .calm: return .secondary
        case .warn: return Color(nsColor: warn)
        case .bad: return Color(nsColor: bad)
        case .unknown: return .secondary
        }
    }
}

/// Heat against the busiest bucket on screen, on a square-root curve so a
/// quiet bucket still shows texture and only a real burst reaches white-hot.
func heatLevel(_ value: Int, ceiling: Int) -> Double {
    guard value > 0 else { return 0 }
    let c = Double(max(ceiling, 20_000))
    return max(0.08, min(1, (Double(value) / c).squareRoot()))
}
