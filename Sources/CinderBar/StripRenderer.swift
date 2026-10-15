import AppKit
import CinderBarCore

/// Where the strip's motion stands at one frame. All of it rides on top of the
/// sampled heat; with `enabled` off the strip is drawn still.
struct StripMotion {
    var enabled = false
    /// Fast ember phase and slow idle drift, both wrapped at 2π and only ever
    /// read at whole harmonics, so the wrap is invisible.
    var ember: Double = 0
    var drift: Double = 0
    /// Monotonic clock for the heartbeats; each takes its own modulo.
    var pulseMs: Double = 0
    /// 0...1 per lane: the flash when new burn lands, fading out.
    var flash: [Agent: Double] = [:]

    /// Eased from `from` to `to` and back over `period`, starting at `from`.
    func pulse(_ period: Double, _ from: Double, _ to: Double) -> Double {
        let t = pulseMs.truncatingRemainder(dividingBy: period) / period
        return from + (to - from) * (0.5 - 0.5 * cos(2 * .pi * t))
    }
}

/// Draws the menu-bar strip:
///
///     CLAUDE ◄── time ──┤ now ├── time ──► CODEX │ GROK ──►   CHIP
///
/// Claude burns on the left, Codex on the right, and the newest bucket of
/// each sits against the centre divider, so the divider is always "now".
/// Grok follows Codex behind a thin rule, newest on its left, as in Burn Bar.
/// Colour carries the token count; height is only a secondary swell.
///
/// The light is Burn Bar's: hot cells flicker like embers and glow past their
/// edges, the strip sits on a bed of light that brightens with total burn, a
/// lane flashes when new burn lands, the live cell breathes, and a plan gauge
/// past 90% beats. At most one thing pulses: a 5-hour chip takes the beat.
enum StripRenderer {
    static let height: CGFloat = 18
    static let cellWidth: CGFloat = 4
    static let cellGap: CGFloat = 1

    /// How hard the machine is working right now: the hottest newest bucket.
    static func energy(snapshot: Snapshot, lanes: [Agent]) -> (level: Double, agent: Agent?) {
        let ceiling = lanes.compactMap { snapshot.agents[$0]?.peakBucket }.max() ?? 0
        var best: (Double, Agent?) = (0, nil)
        for a in lanes {
            let t = heatLevel(snapshot.agents[a]?.buckets.last ?? 0, ceiling: ceiling)
            if t > best.0 { best = (t, a) }
        }
        return best
    }

    static func image(snapshot: Snapshot, lanes: [Agent], standings: [Agent: Standing],
                      chip: Chip?, fault: Bool, motion: StripMotion = StripMotion()) -> NSImage {
        let n = max(1, lanes.compactMap { snapshot.agents[$0]?.buckets.count }.max() ?? 12)
        let laneWidth = CGFloat(n) * (cellWidth + cellGap)
        let stripWidth = lanes.isEmpty ? 30 : laneWidth * CGFloat(lanes.count) + CGFloat(max(0, lanes.count - 1)) * 5
        let chipAttr = chip.map { attributed($0) }
        let chipWidth = chipAttr.map { ceil($0.size().width) + 6 } ?? 0
        let size = NSSize(width: stripWidth + chipWidth, height: height)
        let idle = lanes.allSatisfy { (snapshot.agents[$0]?.buckets.last ?? 0) == 0 }
        let holdPulse = chip?.session == true

        let img = NSImage(size: size, flipped: false) { _ in
            if fault || lanes.isEmpty {
                // Solid red: no idle animation, so an outage cannot hide.
                NSColor(calibratedWhite: 0.5, alpha: 0.35).setFill()
                if fault { Palette.bad.setFill() }
                NSBezierPath(roundedRect: NSRect(x: 0, y: 5, width: stripWidth, height: 8), xRadius: 2, yRadius: 2).fill()
                return true
            }
            drawUnderGlow(snapshot: snapshot, lanes: lanes, width: stripWidth, motion: motion)
            let ceiling = lanes.compactMap { snapshot.agents[$0]?.peakBucket }.max() ?? 0
            var x: CGFloat = 0
            for (i, agent) in lanes.enumerated() {
                let buckets = snapshot.agents[agent]?.buckets ?? []
                // Mirrored pair: the left lane runs newest-right, every lane after it newest-left.
                let newestFirst = i >= 1
                drawLane(buckets: buckets, n: n, agent: agent, ceiling: ceiling, originX: x, newestFirst: newestFirst,
                         motion: motion, idle: idle, holdPulse: holdPulse)
                drawGauge(standings[agent], agent: agent, originX: x, width: laneWidth - cellGap, newestFirst: newestFirst,
                          motion: motion, holdPulse: holdPulse)
                x += laneWidth
                if i < lanes.count - 1 {
                    // The "now" divider is bright; the rule after it is only a separator.
                    NSColor(calibratedWhite: 1, alpha: i == 0 ? 0.75 : 0.25).setFill()
                    NSRect(x: x + 1.5, y: i == 0 ? 2 : 4, width: 1, height: height - (i == 0 ? 4 : 8)).fill()
                    x += 5
                }
            }
            if let chipAttr {
                let s = chipAttr.size()
                // A warning chip breathes, unless a 5-hour chip already owns the beat (it is that chip).
                let alpha = motion.enabled && chip?.warning == true ? motion.pulse(1800, 1, 0.55) : 1
                NSGraphicsContext.current?.cgContext.setAlpha(alpha)
                chipAttr.draw(at: NSPoint(x: stripWidth + 5, y: (height - s.height) / 2))
                NSGraphicsContext.current?.cgContext.setAlpha(1)
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    /// A bed of light under every lane that brightens with total burn: a busy
    /// machine shows from across the room without reading a single cell.
    static func drawUnderGlow(snapshot: Snapshot, lanes: [Agent], width: CGFloat, motion: StripMotion) {
        let e = energy(snapshot: snapshot, lanes: lanes)
        let flash = motion.flash.values.max() ?? 0
        // Softer than Burn Bar's: a menu bar is read from arm's length, and a
        // solid bed would take the contrast away from the cold cells.
        let alpha = 0.03 + 0.14 * pow(e.level, 1.4) + 0.10 * flash
        guard alpha > 0.035, let agent = e.agent else { return }
        let tint = Palette.heat(max(0.45, e.level), agent: agent)
        // Brightest through the middle, fading out above and below the cells.
        let clear = tint.withAlphaComponent(0)
        NSGradient(colors: [clear, tint.withAlphaComponent(alpha), clear])?
            .draw(in: NSRect(x: 0, y: 1, width: width, height: height - 2), angle: 90)
    }

    static func drawLane(buckets: [Int], n: Int, agent: Agent, ceiling: Int, originX: CGFloat, newestFirst: Bool,
                         motion: StripMotion, idle: Bool, holdPulse: Bool) {
        let maxH = height - 6
        let sign: Double = newestFirst ? -1 : 1
        let flash = motion.flash[agent] ?? 0
        for slot in 0..<n {
            // Slot 0 is the leftmost cell of this lane.
            let bi = newestFirst ? buckets.count - 1 - slot : buckets.count - n + slot
            let v = bi >= 0 && bi < buckets.count ? buckets[bi] : 0
            let level = heatLevel(v, ceiling: ceiling)
            // 1 at "now", 0 at the outer edge: the lane reads as a comet tail pointing at now.
            let recency = n <= 1 ? 1 : (newestFirst ? 1 - Double(slot) / Double(n - 1) : Double(slot) / Double(n - 1))
            let live = recency == 1
            // Hot cells flicker harder: cold coals sit still, a live fire does not.
            var move: Double = 0
            if motion.enabled {
                let k = Double(slot)
                move += sin(motion.ember * 2 + k * 0.8 * sign) * 0.06 * level
                    + sin(motion.ember * 3 - k * 0.4 * sign) * 0.035 * level
                move += flash * recency * recency * 0.25
                if idle { move += 0.06 + sin(motion.drift + k * 0.42 * sign) * 0.05 }
            }
            let heat = max(0, min(1, level + move))
            let h = maxH * (0.72 + 0.28 * level) * max(0.6, min(1.3, 1 + 0.28 * move))
            let rect = NSRect(x: originX + CGFloat(slot) * (cellWidth + cellGap), y: 4 + (maxH - h) / 2,
                              width: cellWidth, height: h)
            let tint = v == 0 && heat < 0.02 ? Palette.ember : Palette.heat(max(heat, 0.02), agent: agent)

            // Bloom: a wider, softer ghost behind a hot cell, so it glows past its edges.
            let bloom = pow(level, 1.6) * 0.42 * (0.4 + 0.6 * recency) + flash * recency * recency * 0.45
            if bloom > 0.01 {
                tint.withAlphaComponent(min(1, bloom)).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), xRadius: 2, yRadius: 2).fill()
            }
            // Age fades toward the outer edge; a cold coal stays dim.
            tint.withAlphaComponent(v == 0 && !idle ? 0.55 : 0.58 + 0.42 * recency).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
            // White-hot filament: only once a cell is genuinely hot.
            let core = max(0, heat - 0.55) * 1.5
            if core > 0.01 {
                Palette.whiteHot.withAlphaComponent(min(1, core)).setFill()
                let w = max(1, cellWidth * 0.42), ch = h * 0.42
                NSBezierPath(roundedRect: NSRect(x: rect.midX - w / 2, y: rect.midY - ch / 2, width: w, height: ch),
                             xRadius: w / 2, yRadius: w / 2).fill()
            }
            // The live cell breathes between samples so the lane never looks frozen,
            // and holds still (still marked) while a 5-hour chip owns the beat.
            if live && motion.enabled && !idle {
                let a = holdPulse ? 0.3 : motion.pulse(1800, 0, 0.55)
                Palette.whiteHot.withAlphaComponent(a).setStroke()
                let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 1, yRadius: 1)
                ring.lineWidth = 1
                ring.stroke()
            }
        }
    }

    /// A thin plan gauge under each lane, in a different visual language from
    /// the heat cells so the two scales are never confused. Past 90% it beats:
    /// you should not have to read a number to learn you are about to be cut off.
    static func drawGauge(_ st: Standing?, agent: Agent, originX: CGFloat, width: CGFloat, newestFirst: Bool,
                          motion: StripMotion, holdPulse: Bool) {
        guard let live = st?.live else { return }
        NSColor(calibratedWhite: 1, alpha: 0.18).setFill()
        NSRect(x: originX, y: 0.5, width: width, height: 1.5).fill()
        let w = width * CGFloat(live.used)
        let fill: NSColor = live.spent ? Palette.bad : live.over ? Palette.warn : Palette.ns(agent)
        let beat = motion.enabled && live.used >= 0.9 && !holdPulse ? motion.pulse(1400, 1, 0.35) : 1
        fill.withAlphaComponent(beat).setFill()
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
