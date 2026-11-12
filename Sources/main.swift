// Sugrob: snow on top of the macOS desktop.
// Snow falls in front of all windows and piles up on window top edges and at the bottom of the screen.
// Clicks pass through the snow. Controls live under the ❄️ icon in the menu bar.

import Cocoa
import SpriteKit

// MARK: - Settings

enum Config {
    static let column: CGFloat = 3            // width of one drift column, pt
    static let maxDrift: CGFloat = 34         // maximum drift height on a window
    static let maxSlope: CGFloat = 2.2        // maximum height step between neighbouring columns
    static let flakesPerMegapoint: CGFloat = 115
    static let landChance: CGFloat = 0.6      // share of snowflakes that settle on windows
    static let gain: CGFloat = 1.6            // snow added by one snowflake
    static let mittenRadius: CGFloat = 26
    static let keepAbsent: TimeInterval = 600 // how long to keep the drift of a hidden window, s
    static let maxPuffs = 260
}

enum Tool { case watch, mitten }

enum Settings {
    static var tool: Tool = .watch
    static var clearRequest = 0
}

// MARK: - On-screen windows

struct WinInfo {
    let id: Int
    let rect: CGRect   // global CoreGraphics coordinates: origin top-left, y down
}

final class WindowTracker {
    static let shared = WindowTracker()
    private(set) var windows: [WinInfo] = []   // front to back
    private var last: TimeInterval = 0
    private let myPID = Int(ProcessInfo.processInfo.processIdentifier)

    func refresh(now: TimeInterval) {
        guard abs(now - last) > 0.03 else { return }
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
            result.append(WinInfo(id: id, rect: rect))
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
    private let mitten = SKLabelNode(text: "🧤")

    init(screen: NSScreen) {
        let f = screen.frame
        let v = screen.visibleFrame
        primaryHeight = NSScreen.screens.first?.frame.height ?? f.height
        screenCG = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
        menuBarBottom = max(0, f.maxY - v.maxY)
        let dockAtBottom = v.minY - f.minY > 4
        groundLimit = dockAtBottom ? 12 : 40   // keep a thin layer over the Dock so icons stay visible
        texture = SnowScene.makeTexture()
        super.init(size: f.size)
        scaleMode = .resizeFill
        backgroundColor = .clear
        anchorPoint = .zero

        mitten.fontSize = 26
        mitten.verticalAlignmentMode = .center
        mitten.horizontalAlignmentMode = .center
        mitten.zPosition = 10
        mitten.isHidden = true
        addChild(mitten)

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

    // MARK: Frame

    override func update(_ currentTime: TimeInterval) {
        let dt = CGFloat(min(max(currentTime - lastTime, 0.001), 0.05))
        lastTime = currentTime
        frameIndex += 1

        WindowTracker.shared.refresh(now: currentTime)
        rebuildEdges(now: currentTime)
        stepFlakes(dt)
        stepPuffs(dt)
        applyMitten(dt)
        applyShovel(dt)

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

        // Bottom of the screen
        place(id: -1, x0: 0, y: size.height, width: size.width, limit: groundLimit,
              fronts: rects[0..<rects.count], now: now)

        // Top edges of windows
        for (i, r) in rects.enumerated() {
            guard r.maxX > 0, r.minX < size.width,
                  r.minY > menuBarBottom + 3, r.minY < size.height - 6 else { continue }
            let limit = min(Config.maxDrift, r.minY - menuBarBottom)
            place(id: wins[i].id, x0: r.minX, y: r.minY, width: r.width, limit: limit,
                  fronts: rects[0..<i], now: now)
        }

        // Hidden windows: hide the drift but keep it for a while
        for d in drifts.values where d.seenFrame != frameIndex && !d.node.isHidden {
            d.node.isHidden = true
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
                       fronts: ArraySlice<CGRect>, now: TimeInterval) {
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

        if d.seenFrame != frameIndex - 1 || d.x0 != x0 || d.y != y || d.limit != limit || d.visible != mask {
            d.dirty = true
        }
        d.x0 = x0
        d.y = y
        d.limit = limit
        d.visible = mask
        d.seenFrame = frameIndex
        d.lastSeen = now
        active.append(d)
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

    private func addSnow(_ d: Drift, at c: Int) {
        let n = d.h.count
        d.h[c] = min(d.limit, d.h[c] + Config.gain)
        if c > 0 { d.h[c - 1] = min(d.limit, d.h[c - 1] + Config.gain / 2) }
        if c < n - 1 { d.h[c + 1] = min(d.limit, d.h[c + 1] + Config.gain / 2) }
        d.dirty = true
    }

    // MARK: Drifts

    /// Collapses slopes that are too steep. Returns true while snow is still moving.
    private func relax(_ d: Drift) -> Bool {
        let n = d.h.count
        guard n > 2 else { return false }
        var moved: CGFloat = 0
        for _ in 0..<2 {
            for i in 0..<(n - 1) {
                let diff = d.h[i] - d.h[i + 1]
                let a = abs(diff)
                if a > Config.maxSlope {
                    let m = (a - Config.maxSlope) * 0.5
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
        d.h[0] = min(d.h[0], 1.5)
        d.h[n - 1] = min(d.h[n - 1], 1.5)
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

    // MARK: Mitten

    private func applyMitten(_ dt: CGFloat) {
        let m = NSEvent.mouseLocation
        let p = CGPoint(x: m.x - screenCG.minX, y: (primaryHeight - m.y) - screenCG.minY)
        let inside = p.x >= 0 && p.x <= size.width && p.y >= 0 && p.y <= size.height
        guard Settings.tool == .mitten, inside else {
            mitten.isHidden = true
            lastCursor = nil
            return
        }
        mitten.isHidden = false
        mitten.position = CGPoint(x: p.x + 16, y: size.height - p.y - 18)

        var vx: CGFloat = 0
        var vy: CGFloat = 0
        if let prev = lastCursor {
            vx = max(-900, min(900, (p.x - prev.x) / dt))
            vy = max(-900, min(900, (p.y - prev.y) / dt))
        }
        lastCursor = p

        let radius = Config.mittenRadius
        let col = Config.column
        for d in active {
            guard p.y > d.y - d.limit - radius, p.y < d.y + 10 else { continue }
            let c0 = max(0, Int(((p.x - radius - d.x0) / col).rounded(.down)))
            let c1 = min(d.h.count - 1, Int(((p.x + radius - d.x0) / col).rounded(.down)))
            guard c0 <= c1 else { continue }
            for c in c0...c1 where d.visible[c] && d.h[c] > 0.2 {
                let surface = d.y - d.h[c]
                guard p.y > surface - radius else { continue }
                let cx = d.x0 + (CGFloat(c) + 0.5) * col
                let k = max(0, 1 - abs(cx - p.x) / radius)
                let remove = min(d.h[c], d.h[c] * min(1, k * 12 * dt) + 20 * dt * k)
                d.h[c] -= remove
                d.dirty = true
                if remove > 0.12 && Int.random(in: 0..<3) == 0 {
                    spawnPuff(x: cx, y: surface, vx: vx * 0.3, vy: min(0, vy * 0.2))
                }
            }
        }
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

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var windows: [NSWindow] = []
    private var views: [SKView] = []
    private var paused = false

    private let pauseItem = NSMenuItem(title: "Pause", action: #selector(AppDelegate.togglePause), keyEquivalent: "p")
    private let watchItem = NSMenuItem(title: "Just watch", action: #selector(AppDelegate.chooseWatch), keyEquivalent: "")
    private let mittenItem = NSMenuItem(title: "Mitten: sweep snow with the cursor", action: #selector(AppDelegate.chooseMitten), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        rebuildOverlays()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
    }

    private func setupMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "❄️"
        let menu = NSMenu()
        let shovel = NSMenuItem(title: "Shovel: clear everything", action: #selector(shovelAll), keyEquivalent: "")
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        for entry in [pauseItem, NSMenuItem.separator(), watchItem, mittenItem, shovel, NSMenuItem.separator(), quit] {
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

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
