// Sugrob: snow on top of the macOS desktop.
// Snow falls in front of all windows and piles up on window top edges and at the bottom of the screen.
// Clicks pass through the snow. Controls live under the ❄️ icon in the menu bar.

import Cocoa
import SpriteKit
import ApplicationServices

// MARK: - Settings

enum Config {
    static let column: CGFloat = 3            // width of one drift column, pt
    static let maxDrift: CGFloat = 34         // maximum drift height on a window
    static let maxSlope: CGFloat = 2.2        // maximum height step between neighbouring columns
    static let flakesPerMegapoint: CGFloat = 115
    static let landChance: CGFloat = 0.6      // share of snowflakes that settle on windows
    static let gain: CGFloat = 1.6            // snow added by one snowflake
    static let mittenRadius: CGFloat = 26
    static let cursorRadius: CGFloat = 14     // the plain cursor pushes snow in a narrow strip
    static let shedSpeed: CGFloat = 700       // window speed (pt/s) at which snow starts to shed
    static let shedAccel: CGFloat = 9000      // window jerk that knocks snow off
    static let slideAccel: CGFloat = 2500     // acceleration that makes snow slide along the window
    static let dockInset: CGFloat = 5         // how far the Dock top sits above the icon row
    static let keepAbsent: TimeInterval = 600 // how long to keep the drift of a hidden window, s
    static let maxPuffs = 260
    static let maxChunks = 1500
    static let collapseDelay: TimeInterval = 0.3  // delay before the snow of a vanished window falls
    static let tractorSpeed: CGFloat = 90
    static let tractorTrigger: CGFloat = 0.6       // the tractor comes out when the ground is this full
}

enum Tool { case watch, mitten }

enum Settings {
    static var tool: Tool = .watch
    static var clearRequest = 0
    static var tractorRequest = 0
    static var spaceChangedAt: TimeInterval = -100
    static var minimizeEvents: [MinimizeEvent] = []
    static var dockRect: CGRect?      // Dock icon row, global CG coordinates
}

struct MinimizeEvent {
    let pid: Int
    let rect: CGRect?
    let time: TimeInterval
}

// MARK: - On-screen windows

struct WinInfo {
    let id: Int
    let pid: Int
    let rect: CGRect   // global CoreGraphics coordinates: origin top-left, y down
}

final class WindowTracker {
    static let shared = WindowTracker()
    private(set) var windows: [WinInfo] = []   // front to back
    private var last: TimeInterval = 0
    private let myPID = Int(ProcessInfo.processInfo.processIdentifier)

    func refresh(now: TimeInterval) {
        guard abs(now - last) > 0.012 else { return }
        last = now
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return }
        var result: [WinInfo] = []
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? Int, pid != myPID,
                  let id = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary)
            else { continue }
            let alpha = (w[kCGWindowAlpha as String] as? Double) ?? 1
            guard alpha > 0.05, rect.width >= 120, rect.height >= 60 else { continue }
            result.append(WinInfo(id: id, pid: pid, rect: rect))
        }
        windows = result
    }
}

// MARK: - Simulation data (no logic; all SpriteKit work happens in the scene)

final class Flake {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var vx: CGFloat = 0
    var vy: CGFloat = 0
    var phase: CGFloat = 0
    var sway: CGFloat = 1
    var lands = true
    var life: CGFloat = 0
    var owner: Drift?             // drift the clump broke off from: it does not land back on it
    let node: SKSpriteNode
    init(node: SKSpriteNode) { self.node = node }
}

final class Drift {
    var h: [CGFloat] = []         // snow height per column
    var visible: [Bool] = []      // whether the column is visible (not covered by another window)
    var x0: CGFloat = 0           // left edge, screen-local coordinates
    var y: CGFloat = 0            // line the snow rests on (y down)
    var limit: CGFloat = 0
    var seenFrame = -1
    var lastSeen: TimeInterval = 0
    var dirty = true
    var pid = 0
    var globalRect = CGRect.zero
    var moveX: CGFloat = 0        // window shift during the last frame
    var moveY: CGFloat = 0
    var velX: CGFloat = 0         // smoothed window velocity
    var velY: CGFloat = 0
    var agitated = false          // the window is being moved: snow settles flatter
    var spillLeft: CGFloat = 0    // snow waiting to fall off the left and right edges
    var spillRight: CGFloat = 0
    var missingSince: TimeInterval?
    var parked = false            // window is on another Space: the drift waits for it
    let node: SKShapeNode
    init(node: SKShapeNode) { self.node = node }
}

// MARK: - Scene for one screen

final class SnowScene: SKScene {
    private let screenCG: CGRect          // screen rect in global CG coordinates
    private let primaryHeight: CGFloat
    private let menuBarBottom: CGFloat
    private let groundLimit: CGFloat
    private let texture: SKTexture

    private var flakes: [Flake] = []
    private var puffs: [Flake] = []
    private var drifts: [Int: Drift] = [:]
    private var active: [Drift] = []
    private var frameIndex = 0
    private var lastTime: TimeInterval = 0
    private var lastCursor: CGPoint?
    private var clearSeen = Settings.clearRequest
    private var clearing: CGFloat = 0
    private var chunks: [Flake] = []
    private var suppressed: [Int: TimeInterval] = [:]   // minimized windows that get no snow for now
    private let mitten = SKSpriteNode(texture: SnowScene.makeMittenTexture())
    private let tractor = SKSpriteNode(texture: SnowScene.makeTractorTexture())
    private var tractorActive = false
    private var tractorX: CGFloat = 0
    private var tractorDir: CGFloat = 1
    private var tractorSeen = Settings.tractorRequest
    private var nextTractorCheck: TimeInterval = 0

    init(screen: NSScreen) {
        let f = screen.frame
        let v = screen.visibleFrame
        primaryHeight = NSScreen.screens.first?.frame.height ?? f.height
        screenCG = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
        menuBarBottom = max(0, f.maxY - v.maxY)
        let dockAtBottom = v.minY - f.minY > 4
        groundLimit = dockAtBottom ? 28 : 40   // lower layer over the Dock to cover less of the icons
        texture = SnowScene.makeTexture()
        super.init(size: f.size)
        scaleMode = .resizeFill
        backgroundColor = .clear
        anchorPoint = .zero

        mitten.zPosition = 10
        mitten.zRotation = 0.25
        mitten.isHidden = true
        addChild(mitten)

        tractor.zPosition = 5
        tractor.isHidden = true
        addChild(tractor)

        let count = Int(f.width * f.height / 1_000_000 * Config.flakesPerMegapoint)
        for _ in 0..<max(40, count) {
            let node = SKSpriteNode(texture: texture)
            node.zPosition = 2
            addChild(node)
            let flake = Flake(node: node)
            respawn(flake, anywhere: true)
            flakes.append(flake)
        }
    }

    required init?(coder aDecoder: NSCoder) { fatalError("not supported") }

    private static func makeTexture() -> SKTexture {
        let s: CGFloat = 32
        let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let space = CGColorSpaceCreateDeviceRGB()
            let colors = [
                CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                CGColor(red: 0.97, green: 0.98, blue: 1, alpha: 0.9),
                CGColor(red: 0.8, green: 0.88, blue: 1, alpha: 0)
            ] as CFArray
            let stops: [CGFloat] = [0, 0.5, 1]
            guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: stops) else { return false }
            let c = CGPoint(x: s / 2, y: s / 2)
            ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: s / 2, options: [])
            return true
        }
        return SKTexture(image: image)
    }

    private static func makeMittenTexture() -> SKTexture {
        let image = NSImage(size: NSSize(width: 34, height: 42), flipped: false) { _ in
            let red = NSColor(calibratedRed: 0.84, green: 0.12, blue: 0.16, alpha: 1)
            let dark = NSColor(calibratedRed: 0.55, green: 0.05, blue: 0.09, alpha: 1)
            let thumb = NSBezierPath(ovalIn: NSRect(x: 2, y: 15, width: 13, height: 17))
            let body = NSBezierPath(roundedRect: NSRect(x: 9, y: 9, width: 21, height: 31), xRadius: 10, yRadius: 10)
            for shape in [thumb, body] {
                red.setFill()
                shape.fill()
                dark.setStroke()
                shape.lineWidth = 1
                shape.stroke()
            }
            // white snowflake
            NSColor.white.setStroke()
            let cx: CGFloat = 19.5
            let cy: CGFloat = 27
            for k in 0..<3 {
                let a = CGFloat(k) * CGFloat.pi / 3
                let ray = NSBezierPath()
                ray.move(to: NSPoint(x: cx - cos(a) * 6, y: cy - sin(a) * 6))
                ray.line(to: NSPoint(x: cx + cos(a) * 6, y: cy + sin(a) * 6))
                ray.lineWidth = 1.6
                ray.lineCapStyle = .round
                ray.stroke()
            }
            // row of white dots
            NSColor.white.setFill()
            for x in stride(from: CGFloat(13), through: 26, by: 4.3) {
                NSBezierPath(ovalIn: NSRect(x: x - 1, y: 15, width: 2, height: 2)).fill()
            }
            // white cuff
            let cuff = NSBezierPath(roundedRect: NSRect(x: 7, y: 2, width: 25, height: 10), xRadius: 4, yRadius: 4)
            NSColor.white.setFill()
            cuff.fill()
            let rib = NSColor(calibratedRed: 0.68, green: 0.75, blue: 0.86, alpha: 1)
            rib.setStroke()
            cuff.lineWidth = 1
            cuff.stroke()
            for x in stride(from: CGFloat(12), through: 27, by: 5) {
                let line = NSBezierPath()
                line.move(to: NSPoint(x: x, y: 4.5))
                line.line(to: NSPoint(x: x, y: 9.5))
                line.lineWidth = 1
                line.stroke()
            }
            return true
        }
        return SKTexture(image: image)
    }

    /// The tractor faces right; size 72×48, wheels sit on the bottom edge.
    private static func makeTractorTexture() -> SKTexture {
        let image = NSImage(size: NSSize(width: 72, height: 48), flipped: false) { _ in
            let red = NSColor(calibratedRed: 0.82, green: 0.14, blue: 0.14, alpha: 1)
            let darkRed = NSColor(calibratedRed: 0.55, green: 0.07, blue: 0.08, alpha: 1)
            let tyre = NSColor(calibratedWhite: 0.16, alpha: 1)
            let hub = NSColor(calibratedWhite: 0.8, alpha: 1)
            let steel = NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.1, alpha: 1)

            // exhaust pipe
            tyre.setFill()
            NSBezierPath(rect: NSRect(x: 47, y: 27, width: 3, height: 12)).fill()
            // hood
            red.setFill()
            NSBezierPath(roundedRect: NSRect(x: 24, y: 13, width: 35, height: 16), xRadius: 4, yRadius: 4).fill()
            // cabin
            NSBezierPath(roundedRect: NSRect(x: 8, y: 20, width: 23, height: 24), xRadius: 3, yRadius: 3).fill()
            NSColor(calibratedRed: 0.8, green: 0.91, blue: 1, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 12, y: 28, width: 15, height: 12), xRadius: 2, yRadius: 2).fill()
            // roof with snow on it
            darkRed.setFill()
            NSBezierPath(roundedRect: NSRect(x: 6, y: 42, width: 27, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: 7, y: 44.5, width: 25, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
            // headlight
            NSColor(calibratedRed: 1, green: 0.9, blue: 0.4, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 56, y: 20, width: 5, height: 5)).fill()
            // arm and blade
            tyre.setFill()
            NSBezierPath(rect: NSRect(x: 54, y: 8, width: 10, height: 3)).fill()
            steel.setFill()
            let blade = NSBezierPath()
            blade.move(to: NSPoint(x: 62, y: 1))
            blade.line(to: NSPoint(x: 70, y: 1))
            blade.curve(to: NSPoint(x: 69, y: 24), controlPoint1: NSPoint(x: 64, y: 8), controlPoint2: NSPoint(x: 64, y: 17))
            blade.line(to: NSPoint(x: 65, y: 24))
            blade.curve(to: NSPoint(x: 62, y: 1), controlPoint1: NSPoint(x: 60, y: 17), controlPoint2: NSPoint(x: 60, y: 8))
            blade.close()
            blade.fill()
            // wheels
            for (cx, cy, r) in [(CGFloat(20), CGFloat(14), CGFloat(14)), (CGFloat(49), CGFloat(9), CGFloat(9))] {
                tyre.setFill()
                NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)).fill()
                hub.setFill()
                NSBezierPath(ovalIn: NSRect(x: cx - r * 0.4, y: cy - r * 0.4, width: r * 0.8, height: r * 0.8)).fill()
            }
            return true
        }
        return SKTexture(image: image)
    }

    // MARK: Frame

    override func update(_ currentTime: TimeInterval) {
        let dt = CGFloat(min(max(currentTime - lastTime, 0.001), 0.05))
        lastTime = currentTime
        frameIndex += 1

        let now = ProcessInfo.processInfo.systemUptime
        WindowTracker.shared.refresh(now: now)
        rebuildEdges(now: now)
        stepFlakes(dt)
        stepChunks(dt)
        stepPuffs(dt)
        applyShake(dt)
        applyCursor(dt)
        applyShovel(dt)
        stepTractor(dt, now: now)

        for d in active where d.dirty {
            let moving = relax(d)
            redraw(d)
            d.dirty = moving
        }
    }

    // MARK: Window edges

    private func rebuildEdges(now: TimeInterval) {
        active.removeAll(keepingCapacity: true)
        let wins = WindowTracker.shared.windows
        var rects: [CGRect] = []
        rects.reserveCapacity(wins.count)
        for w in wins {
            rects.append(w.rect.offsetBy(dx: -screenCG.minX, dy: -screenCG.minY))
        }

        // Windows that were just minimized: snow falls right away
        for e in Settings.minimizeEvents where now - e.time < 1.0 {
            var target: Int?
            if let r = e.rect {
                for (key, d) in drifts where key >= 0 && d.pid == e.pid && SnowScene.near(d.globalRect, r) {
                    target = key
                    break
                }
            } else if let w = wins.first(where: { $0.pid == e.pid }) {
                target = w.id
            }
            if let key = target, let d = drifts[key] {
                if d.seenFrame == frameIndex - 1 { collapse(d) }
                d.node.removeFromParent()
                drifts[key] = nil
                suppressed[key] = now + 2.5
            }
        }
        if frameIndex % 120 == 0 {
            suppressed = suppressed.filter { $0.value > now }
        }

        // Bottom of the screen
        place(id: -1, x0: 0, y: size.height, width: size.width, limit: groundLimit,
              fronts: rects[0..<rects.count], now: now)

        // Dock (when its bounds are known)
        if let dock = Settings.dockRect, dock.width > dock.height {
            let r = dock.offsetBy(dx: -screenCG.minX, dy: -screenCG.minY)
            let top = r.minY - Config.dockInset
            if r.maxX > 0, r.minX < size.width, top > menuBarBottom + 40, top < size.height - 6 {
                place(id: -2, x0: r.minX - 8, y: top, width: r.width + 16, limit: Config.maxDrift,
                      fronts: rects[0..<0], now: now)
            }
        }

        // Top edges of windows
        for (i, r) in rects.enumerated() {
            guard r.maxX > 0, r.minX < size.width,
                  r.minY > menuBarBottom + 3, r.minY < size.height - 6 else { continue }
            if let until = suppressed[wins[i].id], now < until { continue }
            let limit = min(Config.maxDrift, r.minY - menuBarBottom)
            place(id: wins[i].id, x0: r.minX, y: r.minY, width: r.width, limit: limit,
                  fronts: rects[0..<i], now: now, pid: wins[i].pid, global: wins[i].rect)
        }

        // The window is gone. If the Space changed, hide the drift and keep it.
        // If the window was closed or minimized, its snow falls down.
        var collapsed: [Int] = []
        for (key, d) in drifts where d.seenFrame != frameIndex && !d.parked {
            if key < 0 {
                d.node.isHidden = true
                continue
            }
            guard let since = d.missingSince else {
                d.missingSince = now
                continue
            }
            guard now - since > Config.collapseDelay else { continue }
            if abs(Settings.spaceChangedAt - since) < 1.2 {
                d.parked = true
                d.node.isHidden = true
            } else {
                collapsed.append(key)
            }
        }
        for key in collapsed {
            if let d = drifts[key] {
                collapse(d)
                d.node.removeFromParent()
                drifts[key] = nil
            }
        }
        if frameIndex % 120 == 0 {
            let stale = drifts.filter { now - $0.value.lastSeen > Config.keepAbsent }
            for (key, d) in stale {
                d.node.removeFromParent()
                drifts[key] = nil
            }
        }
    }

    private func place(id: Int, x0: CGFloat, y: CGFloat, width: CGFloat, limit: CGFloat,
                       fronts: ArraySlice<CGRect>, now: TimeInterval,
                       pid: Int = 0, global: CGRect = .zero) {
        let d: Drift
        if let existing = drifts[id] {
            d = existing
        } else {
            let node = SKShapeNode()
            node.fillColor = .white
            node.strokeColor = NSColor(calibratedRed: 0.72, green: 0.8, blue: 0.9, alpha: 0.9)
            node.lineWidth = 1
            node.isAntialiased = true
            node.zPosition = 1
            node.isHidden = true
            addChild(node)
            d = Drift(node: node)
            drifts[id] = d
        }

        let cols = max(1, Int((width / Config.column).rounded(.up)))
        if d.h.count != cols {
            if d.h.count > cols {
                d.h.removeLast(d.h.count - cols)
            } else {
                d.h.append(contentsOf: [CGFloat](repeating: 0, count: cols - d.h.count))
            }
            d.dirty = true
        }

        // Windows in front that may cover the snow strip
        var blockers: [CGRect] = []
        for f in fronts where f.maxY > y - limit && f.minY < y + 1 && f.maxX > x0 && f.minX < x0 + width {
            blockers.append(f)
        }
        var mask = [Bool](repeating: true, count: cols)
        for c in 0..<cols {
            let x = x0 + (CGFloat(c) + 0.5) * Config.column
            if x < 0 || x > size.width { mask[c] = false; continue }
            for b in blockers where x >= b.minX && x <= b.maxX {
                mask[c] = false
                break
            }
        }

        if d.seenFrame == frameIndex - 1 {
            d.moveX = x0 - d.x0
            d.moveY = y - d.y
        } else {
            d.moveX = 0
            d.moveY = 0
            d.velX = 0
            d.velY = 0
        }
        d.pid = pid
        d.globalRect = global

        if d.seenFrame != frameIndex - 1 || d.x0 != x0 || d.y != y || d.limit != limit || d.visible != mask {
            d.dirty = true
        }
        d.x0 = x0
        d.y = y
        d.limit = limit
        d.visible = mask
        d.seenFrame = frameIndex
        d.lastSeen = now
        d.missingSince = nil
        d.parked = false
        active.append(d)
    }

    private static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        return abs(a.minX - b.minX) < 4 && abs(a.minY - b.minY) < 4
            && abs(a.width - b.width) < 4 && abs(a.height - b.height) < 4
    }

    // MARK: Snowflakes

    private func respawn(_ f: Flake, anywhere: Bool) {
        f.x = CGFloat.random(in: -20...(size.width + 20))
        f.y = anywhere ? CGFloat.random(in: 0...size.height) : -CGFloat.random(in: 4...40)
        let depth = CGFloat.random(in: 0.35...1)
        f.vy = 30 + depth * 60
        f.vx = CGFloat.random(in: -6...6)
        f.sway = CGFloat.random(in: 0.6...1.8)
        f.phase = CGFloat.random(in: 0...6.28)
        f.lands = depth > 0.5 && CGFloat.random(in: 0...1) < Config.landChance
        let diameter = 2.5 + depth * 4.5
        f.node.size = CGSize(width: diameter, height: diameter)
        f.node.alpha = 0.55 + depth * 0.45
    }

    private func stepFlakes(_ dt: CGFloat) {
        let col = Config.column
        for f in flakes {
            f.phase += dt * f.sway
            let nx = f.x + (f.vx + sin(f.phase) * 14) * dt
            let ny = f.y + f.vy * dt
            var landed = false
            if f.lands {
                for d in active {
                    let rel = nx - d.x0
                    guard rel >= 0 else { continue }
                    let c = Int(rel / col)
                    guard c < d.h.count, d.visible[c] else { continue }
                    let surface = d.y - min(d.h[c], d.limit)
                    if f.y <= surface && ny >= surface {
                        addSnow(d, at: c)
                        landed = true
                        break
                    }
                }
            }
            if landed || ny > size.height + 8 || nx < -30 || nx > size.width + 30 {
                respawn(f, anywhere: false)
            } else {
                f.x = nx
                f.y = ny
            }
            f.node.position = CGPoint(x: f.x, y: size.height - f.y)
        }
    }

    /// Puts snow on a column and its two neighbours. Returns how much did not fit.
    @discardableResult
    private func addSnow(_ d: Drift, at c: Int, amount: CGFloat = Config.gain) -> CGFloat {
        let n = d.h.count
        var left: CGFloat = 0
        let targets: [(Int, CGFloat)] = [(c, amount), (c - 1, amount / 2), (c + 1, amount / 2)]
        for (i, part) in targets {
            if i < 0 || i >= n {
                left += part
                continue
            }
            let room = max(0, d.limit - d.h[i])
            let placed = min(room, part)
            d.h[i] += placed
            left += part - placed
        }
        d.dirty = true
        return left
    }

    // MARK: Snow falling off a closed window

    private func spawnChunk(x: CGFloat, y: CGFloat, vx: CGFloat, vy: CGFloat, amount: CGFloat, owner: Drift?) {
        guard chunks.count < Config.maxChunks else { return }
        let node = SKSpriteNode(texture: texture)
        let diameter = 4 + min(amount, 60) * 0.1
        node.size = CGSize(width: diameter, height: diameter)
        node.zPosition = 3
        addChild(node)
        let chunk = Flake(node: node)
        chunk.x = x
        chunk.y = y
        chunk.vx = vx
        chunk.vy = vy
        chunk.life = amount
        chunk.owner = owner
        node.position = CGPoint(x: x, y: size.height - y)
        chunks.append(chunk)
    }

    private func collapse(_ d: Drift) {
        let col = Config.column
        var c = 0
        while c < d.h.count {
            let second = c + 1 < d.h.count ? d.h[c + 1] : 0
            let amount = min(d.h[c], d.limit) + min(second, d.limit)
            if amount > 0.6 && d.visible[c] {
                spawnChunk(x: d.x0 + (CGFloat(c) + 1) * col, y: d.y - amount / 4,
                           vx: CGFloat.random(in: -14...14), vy: CGFloat.random(in: 0...50),
                           amount: amount, owner: nil)
            }
            c += 2
        }
    }

    private func stepChunks(_ dt: CGFloat) {
        let col = Config.column
        var i = chunks.count - 1
        while i >= 0 {
            let p = chunks[i]
            p.vy = min(700, p.vy + 420 * dt)
            let nx = p.x + p.vx * dt
            let ny = p.y + p.vy * dt
            var done = ny > size.height + 10
            if !done {
                for d in active where d !== p.owner {
                    let rel = nx - d.x0
                    guard rel >= 0 else { continue }
                    let c = Int(rel / col)
                    guard c < d.h.count, d.visible[c] else { continue }
                    let surface = d.y - min(d.h[c], d.limit)
                    if p.y <= surface && ny >= surface {
                        let left = addSnow(d, at: c, amount: p.life / 2)
                        if left > 1 {
                            // the drift is full: the remainder keeps falling
                            p.life = left
                            p.owner = d
                        } else {
                            done = true
                        }
                        break
                    }
                }
            }
            if done {
                p.node.removeFromParent()
                chunks.swapAt(i, chunks.count - 1)
                chunks.removeLast()
            } else {
                p.x = nx
                p.y = ny
                p.node.position = CGPoint(x: nx, y: size.height - ny)
            }
            i -= 1
        }
    }

    // MARK: Drifts

    /// Collapses slopes that are too steep. Returns true while snow is still moving.
    private func relax(_ d: Drift) -> Bool {
        let n = d.h.count
        guard n > 2 else { return false }
        var moved: CGFloat = 0
        let slope = d.agitated ? Config.maxSlope * 0.6 : Config.maxSlope
        for _ in 0..<2 {
            for i in 0..<(n - 1) {
                let diff = d.h[i] - d.h[i + 1]
                let a = abs(diff)
                if a > slope {
                    let m = (a - slope) * 0.5
                    if diff > 0 {
                        d.h[i] -= m
                        d.h[i + 1] += m
                    } else {
                        d.h[i] += m
                        d.h[i + 1] -= m
                    }
                    moved += m
                }
            }
        }
        // Snow that reaches the window edge falls off as a clump instead of vanishing
        if d.h[0] > 1.5 {
            d.spillLeft += d.h[0] - 1.5
            d.h[0] = 1.5
        }
        if d.h[n - 1] > 1.5 {
            d.spillRight += d.h[n - 1] - 1.5
            d.h[n - 1] = 1.5
        }
        let width = CGFloat(n) * Config.column
        if d.spillLeft > 2.5 {
            if d.visible[0] {
                spawnChunk(x: d.x0 - 1, y: d.y - 2, vx: -CGFloat.random(in: 8...30), vy: 0,
                           amount: d.spillLeft, owner: d)
            }
            d.spillLeft = 0
        }
        if d.spillRight > 2.5 {
            if d.visible[n - 1] {
                spawnChunk(x: d.x0 + width + 1, y: d.y - 2, vx: CGFloat.random(in: 8...30), vy: 0,
                           amount: d.spillRight, owner: d)
            }
            d.spillRight = 0
        }
        return moved > 0.05
    }

    private func redraw(_ d: Drift) {
        let col = Config.column
        let base = size.height - d.y
        let path = CGMutablePath()
        var open = false
        var lastX: CGFloat = 0
        for c in 0..<d.h.count {
            let hh = min(d.h[c], d.limit)
            let xl = d.x0 + CGFloat(c) * col
            if d.visible[c] && hh > 0.4 {
                if !open {
                    path.move(to: CGPoint(x: xl, y: base))
                    open = true
                }
                path.addLine(to: CGPoint(x: xl + col / 2, y: base + hh))
                lastX = xl + col
            } else if open {
                path.addLine(to: CGPoint(x: lastX, y: base))
                path.closeSubpath()
                open = false
            }
        }
        if open {
            path.addLine(to: CGPoint(x: lastX, y: base))
            path.closeSubpath()
        }
        if path.isEmpty {
            d.node.path = nil
            d.node.isHidden = true
        } else {
            d.node.path = path
            d.node.isHidden = false
        }
    }

    // MARK: Snow spray

    private func spawnPuff(x: CGFloat, y: CGFloat, vx: CGFloat, vy: CGFloat) {
        guard puffs.count < Config.maxPuffs else { return }
        let node = SKSpriteNode(texture: texture)
        let diameter = CGFloat.random(in: 3...6)
        node.size = CGSize(width: diameter, height: diameter)
        node.zPosition = 3
        addChild(node)
        let p = Flake(node: node)
        p.x = x
        p.y = y
        p.vx = vx + CGFloat.random(in: -45...45)
        p.vy = vy - CGFloat.random(in: 30...110)
        p.life = CGFloat.random(in: 0.7...1.3)
        node.position = CGPoint(x: x, y: size.height - y)
        puffs.append(p)
    }

    private func stepPuffs(_ dt: CGFloat) {
        var i = puffs.count - 1
        while i >= 0 {
            let p = puffs[i]
            p.life -= dt
            p.vy += 260 * dt
            p.x += p.vx * dt
            p.y += p.vy * dt
            if p.life <= 0 || p.y > size.height + 10 {
                p.node.removeFromParent()
                puffs.swapAt(i, puffs.count - 1)
                puffs.removeLast()
            } else {
                p.node.alpha = min(1, p.life * 2)
                p.node.position = CGPoint(x: p.x, y: size.height - p.y)
            }
            i -= 1
        }
    }

    // MARK: Window motion: snow slides and sheds

    private func applyShake(_ dt: CGFloat) {
        let col = Config.column
        for d in active {
            let oldVX = d.velX
            let oldVY = d.velY
            d.velX = oldVX * 0.5 + (d.moveX / dt) * 0.5
            d.velY = oldVY * 0.5 + (d.moveY / dt) * 0.5
            let speed = (d.velX * d.velX + d.velY * d.velY).squareRoot()
            let wasAgitated = d.agitated
            d.agitated = speed > 40
            if d.agitated || wasAgitated { d.dirty = true }
            guard speed > 1 || abs(oldVX) > 1 || abs(oldVY) > 1 else { continue }

            let ax = (d.velX - oldVX) / dt
            let ay = (d.velY - oldVY) / dt
            let accel = (ax * ax + ay * ay).squareRoot()
            let n = d.h.count

            // Snow lags behind the window and slides against the acceleration
            if abs(ax) > Config.slideAccel && n > 1 {
                let f = min(0.45, (abs(ax) - Config.slideAccel) / 25000)
                if ax > 0 {
                    for c in 0..<(n - 1) {
                        let m = d.h[c + 1] * f
                        d.h[c + 1] -= m
                        d.h[c] += m
                    }
                } else {
                    for c in stride(from: n - 1, to: 0, by: -1) {
                        let m = d.h[c - 1] * f
                        d.h[c - 1] -= m
                        d.h[c] += m
                    }
                }
                d.dirty = true
            }

            // Fast dragging and jerks knock snow off in clumps
            let bySpeed = min(4, max(0, (speed - Config.shedSpeed) / 600))
            let byJerk = min(8, max(0, (accel - Config.shedAccel) / 6000))
            let rate = bySpeed + byJerk
            guard rate > 0 else { continue }
            let chance = min(1, rate * dt * 2)
            var loose: CGFloat = 0
            for c in 0..<n where d.visible[c] && d.h[c] > 0.5 {
                guard CGFloat.random(in: 0...1) < chance else { continue }
                let amount = d.h[c] * CGFloat.random(in: 0.3...0.8)
                d.h[c] -= amount
                loose += amount
                if loose > 3 {
                    spawnChunk(x: d.x0 + (CGFloat(c) + 0.5) * col, y: d.y - d.h[c] - 1,
                               vx: oldVX * 0.5 + CGFloat.random(in: -25...25),
                               vy: min(oldVY * 0.5, 60) + CGFloat.random(in: -30...10),
                               amount: loose, owner: d)
                    loose = 0
                }
            }
            d.dirty = true
        }
    }

    // MARK: Cursor and mitten

    /// The cursor always pushes snow into a heap ahead of it; the mitten is wider and sweeps more away.
    private func applyCursor(_ dt: CGFloat) {
        let m = NSEvent.mouseLocation
        let p = CGPoint(x: m.x - screenCG.minX, y: (primaryHeight - m.y) - screenCG.minY)
        let inside = p.x >= 0 && p.x <= size.width && p.y >= 0 && p.y <= size.height
        guard inside else {
            mitten.isHidden = true
            lastCursor = nil
            return
        }
        let isMitten = Settings.tool == .mitten
        mitten.isHidden = !isMitten
        if isMitten {
            mitten.position = CGPoint(x: p.x + 14, y: size.height - p.y - 20)
        }

        var vx: CGFloat = 0
        var vy: CGFloat = 0
        if let prev = lastCursor {
            vx = max(-1500, min(1500, (p.x - prev.x) / dt))
            vy = max(-1500, min(1500, (p.y - prev.y) / dt))
        }
        lastCursor = p
        let speed = (vx * vx + vy * vy).squareRoot()

        let radius = isMitten ? Config.mittenRadius : Config.cursorRadius
        // share of touched snow that flies off instead of being pushed into a heap
        let fling = isMitten ? min(1, 0.55 + speed / 1500) : min(0.5, max(0, (speed - 900) / 2000))
        let dirX: CGFloat = vx > 20 ? 1 : (vx < -20 ? -1 : 0)
        let col = Config.column

        for d in active {
            let n = d.h.count
            guard p.y > d.y - d.limit - radius, p.y < d.y + 6 else { continue }
            let c0 = max(0, Int(((p.x - radius - d.x0) / col).rounded(.down)))
            let c1 = min(n - 1, Int(((p.x + radius - d.x0) / col).rounded(.down)))
            guard c0 <= c1 else { continue }
            var fly: CGFloat = 0
            for c in c0...c1 where d.visible[c] && d.h[c] > 0.2 {
                let surface = d.y - min(d.h[c], d.limit)
                guard p.y > surface - radius * 0.6 else { continue }
                let cx = d.x0 + (CGFloat(c) + 0.5) * col
                let k = max(0, 1 - abs(cx - p.x) / radius)
                let take = min(d.h[c], d.h[c] * min(1, k * 14 * dt) + 25 * dt * k)
                guard take > 0.001 else { continue }
                d.h[c] -= take
                d.dirty = true

                var push = take * (1 - fling)
                fly += take - push
                let side: CGFloat = dirX != 0 ? dirX : (cx >= p.x ? 1 : -1)
                let step = side > 0 ? 1 : -1
                let first = Int(((p.x + side * (radius + 2) - d.x0) / col).rounded(.down))
                for j in 0..<5 {
                    let t = first + step * j
                    guard push > 0.001, t >= 0, t < n, d.visible[t] else { break }
                    let room = d.limit - d.h[t]
                    if room > 0 {
                        let movedSnow = min(room, push)
                        d.h[t] += movedSnow
                        push -= movedSnow
                    }
                }
                fly += push
                if fly > 2.5 {
                    spawnChunk(x: cx, y: surface - 2,
                               vx: vx * 0.35 + CGFloat.random(in: -30...30),
                               vy: -CGFloat.random(in: 40...140),
                               amount: fly, owner: nil)
                    fly = 0
                }
            }
            if fly > 0.4 {
                spawnChunk(x: p.x, y: min(p.y, d.y - 2), vx: vx * 0.35, vy: -CGFloat.random(in: 30...90),
                           amount: fly, owner: nil)
            }
        }
    }

    // MARK: Tractor (state)

    fileprivate func groundDrift() -> Drift? {
        guard let g = drifts[-1], g.seenFrame == frameIndex else { return nil }
        return g
    }

    fileprivate func tractorPosition() -> CGFloat { tractorX }
    fileprivate func tractorDirection() -> CGFloat { tractorDir }

    fileprivate func startTractor() {
        tractorActive = true
        tractorDir = Bool.random() ? 1 : -1
        tractorX = tractorDir > 0 ? -60 : size.width + 60
        tractor.xScale = tractorDir
        tractor.isHidden = false
    }

    fileprivate func advanceTractor(_ dt: CGFloat, now: TimeInterval) {
        tractorX += tractorDir * Config.tractorSpeed * dt
        let bounce = CGFloat(abs(sin(now * 9))) * 1.2
        tractor.position = CGPoint(x: tractorX, y: 24 + bounce)
        if tractorX < -70 || tractorX > size.width + 70 {
            tractorActive = false
            tractor.isHidden = true
            nextTractorCheck = now + 60
        }
    }

    fileprivate func throwSnow(x: CGFloat, direction: CGFloat) {
        spawnPuff(x: x, y: size.height - 16, vx: direction * 130, vy: -30)
    }

    // MARK: Shovel

    private func applyShovel(_ dt: CGFloat) {
        if clearSeen != Settings.clearRequest {
            clearSeen = Settings.clearRequest
            clearing = 0.8
        }
        guard clearing > 0 else { return }
        clearing -= dt
        for d in drifts.values {
            let shown = d.seenFrame == frameIndex
            for c in 0..<d.h.count where d.h[c] > 0 {
                if shown && d.visible[c] && d.h[c] > 2 && Int.random(in: 0..<40) == 0 {
                    let cx = d.x0 + (CGFloat(c) + 0.5) * Config.column
                    spawnPuff(x: cx, y: d.y - d.h[c], vx: 0, vy: 0)
                }
                d.h[c] = clearing > 0 && d.h[c] > 0.3 ? d.h[c] * 0.8 : 0
            }
            d.dirty = true
        }
    }
}

// MARK: - Tractor

extension SnowScene {
    fileprivate func stepTractor(_ dt: CGFloat, now: TimeInterval) {
        guard let ground = groundDrift() else { return }
        let n = ground.h.count
        let col = Config.column

        if !tractorActive {
            var start = false
            if tractorSeen != Settings.tractorRequest {
                tractorSeen = Settings.tractorRequest
                start = true
            } else if now > nextTractorCheck {
                nextTractorCheck = now + 5
                var sum: CGFloat = 0
                var count: CGFloat = 0
                for c in 0..<n where ground.visible[c] {
                    sum += ground.h[c]
                    count += 1
                }
                start = count > 0 && sum / count > ground.limit * Config.tractorTrigger
            }
            guard start else { return }
            startTractor()
        }

        advanceTractor(dt, now: now)
        let rear = tractorPosition() - tractorDirection() * 36
        let blade = tractorPosition() + tractorDirection() * 30
        let c0 = max(0, Int((min(rear, blade) / col).rounded(.down)))
        let c1 = min(n - 1, Int((max(rear, blade) / col).rounded(.down)))
        if c0 <= c1 {
            var carried: CGFloat = 0
            for c in c0...c1 where ground.h[c] > 0.8 {
                carried += ground.h[c] - 0.8
                ground.h[c] = 0.8
            }
            if carried > 0 {
                // snow is pushed into a heap ahead of the blade; the excess is thrown off
                var k = 1
                while carried > 0.01 && k <= 30 {
                    let t = tractorDirection() > 0 ? c1 + k : c0 - k
                    guard t >= 0 && t < n else { break }
                    let room = ground.limit - ground.h[t]
                    if room > 0 {
                        let m = min(room, carried)
                        ground.h[t] += m
                        carried -= m
                    }
                    k += 1
                }
                if carried > 0.2 {
                    throwSnow(x: blade, direction: tractorDirection())
                }
                ground.dirty = true
            }
        }
    }
}

// MARK: - Accessibility: window minimize events and Dock bounds

func axFrame(_ element: AXUIElement) -> CGRect? {
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
          let pos = posRef, let sz = sizeRef,
          CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(sz) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(pos as! AXValue, .cgPoint, &point),
          AXValueGetValue(sz as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}

func axMinimizeCallback(_ observer: AXObserver, _ element: AXUIElement,
                        _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    Settings.minimizeEvents.append(MinimizeEvent(pid: Int(pid), rect: axFrame(element),
                                                 time: ProcessInfo.processInfo.systemUptime))
}

func dockListFrame() -> CGRect? {
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
    let appElement = AXUIElementCreateApplication(dock.processIdentifier)
    var childrenRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
          let children = childrenRef as? [AXUIElement] else { return nil }
    for child in children {
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String, role == (kAXListRole as String) {
            return axFrame(child)
        }
    }
    return nil
}

final class AXWatcher {
    static let shared = AXWatcher()
    private var observers: [pid_t: AXObserver] = [:]

    func sync(pids: Set<pid_t>) {
        for (pid, observer) in observers where !pids.contains(pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            observers[pid] = nil
        }
        for pid in pids where observers[pid] == nil {
            var created: AXObserver?
            guard AXObserverCreate(pid, axMinimizeCallback, &created) == .success,
                  let observer = created else { continue }
            let appElement = AXUIElementCreateApplication(pid)
            guard AXObserverAddNotification(observer, appElement,
                                            kAXWindowMiniaturizedNotification as CFString, nil) == .success
            else { continue }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            observers[pid] = observer
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var windows: [NSWindow] = []
    private var views: [SKView] = []
    private var paused = false

    private let pauseItem = NSMenuItem(title: "Pause", action: #selector(AppDelegate.togglePause), keyEquivalent: "p")
    private let watchItem = NSMenuItem(title: "Just watch", action: #selector(AppDelegate.chooseWatch), keyEquivalent: "")
    private let accessItem = NSMenuItem(title: "Accessibility", action: #selector(AppDelegate.openAccessSettings), keyEquivalent: "")
    private var housekeeping: Timer?
    private let mittenItem = NSMenuItem(title: "Mitten: sweep snow with the cursor", action: #selector(AppDelegate.chooseMitten), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        rebuildOverlays()
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)
        housekeeping = Timer.scheduledTimer(timeInterval: 1.5, target: self, selector: #selector(housekeep),
                                            userInfo: nil, repeats: true)
        housekeep()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged),
                                                          name: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil)
    }

    private func setupMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "❄️"
        let menu = NSMenu()
        let shovel = NSMenuItem(title: "Shovel: clear everything", action: #selector(shovelAll), keyEquivalent: "")
        let plow = NSMenuItem(title: "Call the tractor", action: #selector(callTractor), keyEquivalent: "")
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        for entry in [pauseItem, NSMenuItem.separator(), watchItem, mittenItem, shovel, plow, NSMenuItem.separator(), accessItem, NSMenuItem.separator(), quit] {
            entry.target = self
            menu.addItem(entry)
        }
        item.menu = menu
        statusItem = item
        refreshMenu()
    }

    private func refreshMenu() {
        pauseItem.title = paused ? "Resume snowfall" : "Pause"
        watchItem.state = Settings.tool == .watch ? .on : .off
        mittenItem.state = Settings.tool == .mitten ? .on : .off
    }

    private func rebuildOverlays() {
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        views.removeAll()

        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .statusBar
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.setFrame(screen.frame, display: false)

            let view = SKView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.allowsTransparency = true
            view.ignoresSiblingOrder = true
            view.preferredFramesPerSecond = 30
            view.autoresizingMask = [.width, .height]
            view.presentScene(SnowScene(screen: screen))
            view.isPaused = paused
            window.contentView = view

            if !paused { window.orderFrontRegardless() }
            windows.append(window)
            views.append(view)
        }
    }

    @objc private func screensChanged() {
        rebuildOverlays()
    }

    @objc private func togglePause() {
        paused.toggle()
        for (window, view) in zip(windows, views) {
            view.isPaused = paused
            if paused { window.orderOut(nil) } else { window.orderFrontRegardless() }
        }
        refreshMenu()
    }

    @objc private func chooseWatch() {
        Settings.tool = .watch
        refreshMenu()
    }

    @objc private func chooseMitten() {
        Settings.tool = .mitten
        refreshMenu()
    }

    @objc private func shovelAll() {
        Settings.clearRequest += 1
    }

    @objc private func housekeep() {
        let trusted = AXIsProcessTrusted()
        accessItem.title = trusted ? "Accessibility: enabled ✓" : "Grant Accessibility access…"
        let now = ProcessInfo.processInfo.systemUptime
        Settings.minimizeEvents.removeAll { now - $0.time > 2 }
        if trusted {
            AXWatcher.shared.sync(pids: Set(WindowTracker.shared.windows.map { pid_t($0.pid) }))
            Settings.dockRect = dockListFrame()
        } else {
            Settings.dockRect = nil
        }
    }

    @objc private func openAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func callTractor() {
        Settings.tractorRequest += 1
    }

    @objc private func spaceChanged() {
        Settings.spaceChangedAt = ProcessInfo.processInfo.systemUptime
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
