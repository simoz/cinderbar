import AppKit
import CinderBarCore

/// Draws the menu-bar strip:
///
///     CLAUDE ◄── time ──┤ now ├── time ──► CODEX   CHIP
///
/// Claude burns on the left, Codex on the right, and the newest bucket of
/// each sits against the centre divider, so the divider is always "now".
/// Colour carries the token count; height is only a secondary swell.
enum StripRenderer {
    static let height: CGFloat = 18
    static let cellWidth: CGFloat = 4
    static let cellGap: CGFloat = 1

    static func image(snapshot: Snapshot, lanes: [Agent], standings: [Agent: Standing],
                      chip: Chip?, fault: Bool) -> NSImage {
        let n = max(1, lanes.compactMap { snapshot.agents[$0]?.buckets.count }.max() ?? 12)
        let laneWidth = CGFloat(n) * (cellWidth + cellGap)
        let stripWidth = lanes.isEmpty ? 30 : laneWidth * CGFloat(lanes.count) + (lanes.count > 1 ? 5 : 0)
        let chipAttr = chip.map { attributed($0) }
        let chipWidth = chipAttr.map { ceil($0.size().width) + 6 } ?? 0
        let size = NSSize(width: stripWidth + chipWidth, height: height)

        let img = NSImage(size: size, flipped: false) { _ in
            if fault || lanes.isEmpty {
                // Solid red: no idle animation, so an outage cannot hide.
                NSColor(calibratedWhite: 0.5, alpha: 0.35).setFill()
                if fault { Palette.bad.setFill() }
                NSBezierPath(roundedRect: NSRect(x: 0, y: 5, width: stripWidth, height: 8), xRadius: 2, yRadius: 2).fill()
                return true
            }
            let ceiling = lanes.compactMap { snapshot.agents[$0]?.peakBucket }.max() ?? 0
            var x: CGFloat = 0
            for (i, agent) in lanes.enumerated() {
                let buckets = snapshot.agents[agent]?.buckets ?? []
                // Mirrored pair: the left lane runs newest-right, the right lane newest-left.
                let newestFirst = lanes.count > 1 && i == 1
                drawLane(buckets: buckets, n: n, agent: agent, ceiling: ceiling, originX: x, newestFirst: newestFirst)
                drawGauge(standings[agent], agent: agent, originX: x, width: laneWidth - cellGap, newestFirst: newestFirst)
                x += laneWidth
                if i == 0 && lanes.count > 1 {
                    NSColor(calibratedWhite: 1, alpha: 0.75).setFill()
                    NSRect(x: x + 1.5, y: 2, width: 1, height: height - 4).fill()
                    x += 5
                }
            }
            if let chipAttr {
                let s = chipAttr.size()
                chipAttr.draw(at: NSPoint(x: stripWidth + 5, y: (height - s.height) / 2))
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    static func drawLane(buckets: [Int], n: Int, agent: Agent, ceiling: Int, originX: CGFloat, newestFirst: Bool) {
        let maxH = height - 6
        for slot in 0..<n {
            // Slot 0 is the leftmost cell of this lane.
            let bi = newestFirst ? buckets.count - 1 - slot : buckets.count - n + slot
            let v = bi >= 0 && bi < buckets.count ? buckets[bi] : 0
            let t = heatLevel(v, ceiling: ceiling)
            let h = maxH * (0.72 + 0.28 * t)
            let rect = NSRect(x: originX + CGFloat(slot) * (cellWidth + cellGap), y: 4 + (maxH - h) / 2,
                              width: cellWidth, height: h)
            let c = v == 0 ? Palette.ember.withAlphaComponent(0.55) : Palette.heat(t, agent: agent)
            c.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
            if t > 0.97 {
                // White-hot filament: a cell genuinely at the top of the ramp.
                NSColor.white.setFill()
                NSRect(x: rect.midX - 0.5, y: rect.minY + 1, width: 1, height: rect.height - 2).fill()
            }
        }
    }

    /// A thin plan gauge under each lane, in a different visual language from
    /// the heat cells so the two scales are never confused.
    static func drawGauge(_ st: Standing?, agent: Agent, originX: CGFloat, width: CGFloat, newestFirst: Bool) {
        guard let live = st?.live else { return }
        NSColor(calibratedWhite: 1, alpha: 0.18).setFill()
        NSRect(x: originX, y: 0.5, width: width, height: 1.5).fill()
        let w = width * CGFloat(live.used)
        let fill: NSColor = live.spent ? Palette.bad : live.over ? Palette.warn : Palette.ns(agent)
        fill.setFill()
        // The gauge grows from the outer edge toward "now".
        NSRect(x: newestFirst ? originX + width - w : originX, y: 0.5, width: w, height: 1.5).fill()
    }

    static func attributed(_ chip: Chip) -> NSAttributedString {
        let color: NSColor = chip.warning ? (chip.stage >= 4 ? Palette.bad : Palette.warn) : Palette.ns(chip.agent)
        return NSAttributedString(string: chip.text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold),
            .foregroundColor: color,
            .kern: 0.4,
        ])
    }
}
