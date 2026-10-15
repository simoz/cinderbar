import AppKit
import SwiftUI
import CinderBarCore

enum Palette {
    static let claude = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)   // Claude orange
    static let codex = NSColor(srgbRed: 0.169, green: 0.710, blue: 0.651, alpha: 1)    // Codex teal
    static let grok = NSColor(srgbRed: 1.0, green: 0.42, blue: 0.706, alpha: 1)       // Burn Bar's Grok magenta
    static let ember = NSColor(srgbRed: 0.20, green: 0.09, blue: 0.06, alpha: 1)       // cold coal
    static let amber = NSColor(srgbRed: 1.0, green: 0.71, blue: 0.20, alpha: 1)
    static let whiteHot = NSColor(srgbRed: 1.0, green: 0.97, blue: 0.90, alpha: 1)
    // Text colours get a darker shade on a light background, or they wash out.
    static let warn = dynamic(dark: NSColor(srgbRed: 1.0, green: 0.62, blue: 0.18, alpha: 1),
                              light: NSColor(srgbRed: 0.80, green: 0.40, blue: 0.0, alpha: 1))
    static let bad = dynamic(dark: NSColor(srgbRed: 0.94, green: 0.27, blue: 0.24, alpha: 1),
                             light: NSColor(srgbRed: 0.78, green: 0.13, blue: 0.11, alpha: 1))
    static let good = dynamic(dark: NSColor(srgbRed: 0.40, green: 0.80, blue: 0.45, alpha: 1),
                              light: NSColor(srgbRed: 0.10, green: 0.52, blue: 0.20, alpha: 1))
    static let codexText = dynamic(dark: codex, light: NSColor(srgbRed: 0.04, green: 0.50, blue: 0.45, alpha: 1))
    static let grokText = dynamic(dark: grok, light: NSColor(srgbRed: 0.69, green: 0.16, blue: 0.43, alpha: 1))
    static let claudeText = dynamic(dark: claude, light: NSColor(srgbRed: 0.72, green: 0.33, blue: 0.20, alpha: 1))

    // Panel surfaces: a solid charcoal like Burn Bar's cockpit, or a plain
    // light grey; never the translucent popover material.
    static let panel = dynamic(dark: NSColor(srgbRed: 0.090, green: 0.090, blue: 0.105, alpha: 1),
                               light: NSColor(srgbRed: 0.965, green: 0.965, blue: 0.970, alpha: 1))
    static let card = dynamic(dark: NSColor(srgbRed: 0.140, green: 0.140, blue: 0.160, alpha: 1),
                              light: NSColor.white)
    static let cardEdge = dynamic(dark: NSColor(white: 1, alpha: 0.08), light: NSColor(white: 0, alpha: 0.10))

    static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    static func ns(_ agent: Agent) -> NSColor {
        switch agent { case .claude: return claude; case .codex: return codex; case .grok: return grok }
    }
    /// For text and strokes in the panel; the strip keeps the bright hues.
    static func color(_ agent: Agent) -> Color {
        switch agent {
        case .claude: return Color(nsColor: claudeText)
        case .codex: return Color(nsColor: codexText)
        case .grok: return Color(nsColor: grokText)
        }
    }

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

/// Every type size in the panel goes through here: Burn Bar's sizes were
/// tuned for a Linux bar at arm's length and read small on a Mac.
let textScale: CGFloat = 1.25
func ui(_ size: CGFloat) -> CGFloat { (size * textScale).rounded() }

/// Card width follows the type.
let cardWidth: CGFloat = ui(330)
