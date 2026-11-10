import SwiftUI
import FriendCalCore

/// Which painted backdrop a row wears (variant D, "Scene Rows"). Every status ships with a default
/// scene; busy is a flat grey with no scene at all, so a hidden plan has nothing to show.
enum SceneStyle: Equatable {
    case status(StatusKind)
    case busy
    case quiet
    /// The Pokes tab: a poke still out (ripples), one that was answered, and a friend joining a plan.
    case poke
    case pokeSeen
    case tagAlong
}

/// A painted scene drawn in code: no assets, crisp at any size, a little alive. Props sit in a square
/// "hero" the size of the canvas height, centered at `anchor` (0...1 of the width), so the same scene
/// reads in a wide row, where the name plate covers the right, and in a gallery card. Motion (stage
/// beams, screen glow, steam, drifting clouds, twinkling stars) stops under Reduce Motion and when the
/// app is not active.
struct SceneArt: View {
    let style: SceneStyle
    var anchor: CGFloat = 0.5
    var animates = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let live = animates && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !live || scenePhase != .active)) { timeline in
            Canvas { context, size in
                let t = live ? timeline.date.timeIntervalSinceReferenceDate : 0
                var painter = ScenePainter(context: context, size: size, anchor: anchor, t: t)
                painter.paint(style)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Scene palette. Scenes carry no text, so these are fills only; the name plate on top is the
/// existing ivory surface and keeps its contrast pairs.
private enum Paint {
    static let wood = Color(hex: "#B9835A")
    static let woodDark = Color(hex: "#6B4A33")
    static let night = Color(hex: "#14313A")
    static let nightDeep = Color(hex: "#0B1D22")
    static let seatRed = Color(hex: "#6E2A26")
    static let curtain = Color(hex: "#7A2A22")
    static let stageTop = Color(hex: "#2A1412")
    static let stageBottom = Color(hex: "#5A1F1A")
    static let sky = Color(hex: "#9ED6D0")
    static let ink = Color(hex: "#12090A")
    static let counter = Color(hex: "#2D4A47")
    static let cream = DesignTokens.Colors.background
}

private struct ScenePainter {
    var context: GraphicsContext
    let size: CGSize
    let anchor: CGFloat
    let t: Double

    /// The hero square: side = canvas height, centered at the anchor, clamped inside the canvas.
    private var side: CGFloat { min(size.height, size.width) }
    private var originX: CGFloat { min(max(anchor * size.width - side / 2, 0), size.width - side) }
    private var unit: CGFloat { side / 100 }

    private func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: originX + x * unit, y: y * unit) }
    private func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: originX + x * unit, y: y * unit, width: w * unit, height: h * unit)
    }
    private var canvas: CGRect { CGRect(origin: .zero, size: size) }

    private mutating func backdrop(_ top: Color, _ bottom: Color) {
        context.fill(Path(canvas), with: .linearGradient(Gradient(colors: [top, bottom]),
                                                        startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
    }
    private mutating func rect(_ r: CGRect, _ color: Color, radius: CGFloat = 0, opacity: Double = 1) {
        let path = radius > 0 ? Path(roundedRect: r, cornerRadius: radius * unit) : Path(r)
        context.fill(path, with: .color(color.opacity(opacity)))
    }
    private mutating func disc(_ c: CGPoint, _ r: CGFloat, _ color: Color, opacity: Double = 1) {
        let rr = r * unit
        context.fill(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)), with: .color(color.opacity(opacity)))
    }
    private mutating func poly(_ points: [CGPoint], _ color: Color, opacity: Double = 1) {
        var p = Path()
        p.addLines(points)
        p.closeSubpath()
        context.fill(p, with: .color(color.opacity(opacity)))
    }
    private mutating func glow(_ c: CGPoint, _ r: CGFloat, _ color: Color, opacity: Double) {
        let rr = r * unit
        context.fill(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)),
                     with: .radialGradient(Gradient(colors: [color.opacity(opacity), color.opacity(0)]),
                                           center: c, startRadius: 0, endRadius: rr))
    }

    mutating func paint(_ style: SceneStyle) {
        switch style {
        case .busy: rect(canvas, DesignTokens.Colors.busyGray)
        case .quiet: quiet()
        case .poke: poke()
        case .pokeSeen: pokeSeen()
        case .tagAlong: tagAlong()
        case .status(let kind):
            switch kind {
            case .work: work()
            case .movies: movies()
            case .concert: concert()
            case .gym: gym()
            case .cooking: cooking()
            case .flying: flying()
            case .studying: studying()
            case .napping: napping()
            case .free: free()
            }
        }
    }

    // MARK: Shared props

    private mutating func desk(top: CGFloat = 78) {
        rect(CGRect(x: 0, y: top * unit, width: size.width, height: size.height - top * unit), Paint.wood)
        rect(CGRect(x: 0, y: top * unit, width: size.width, height: 2 * unit), Paint.woodDark, opacity: 0.35)
    }

    private mutating func lamp(at x: CGFloat, deskTop: CGFloat = 78) {
        glow(pt(x, 46), 34, DesignTokens.Colors.warning, opacity: 0.5)
        var arm = Path()
        arm.move(to: pt(x + 6, deskTop))
        arm.addLine(to: pt(x + 16, 52))
        arm.addLine(to: pt(x, 34))
        context.stroke(arm, with: .color(DesignTokens.Colors.accentHover), style: StrokeStyle(lineWidth: 2.4 * unit, lineCap: .round, lineJoin: .round))
        poly([pt(x - 12, 41), pt(x + 12, 41), pt(x + 6, 24), pt(x - 6, 24)], DesignTokens.Colors.accentHover)
        rect(box(x - 2, deskTop - 3, 16, 4), DesignTokens.Colors.accentHover, radius: 2)
    }

    // MARK: Scenes

    private mutating func work() {
        backdrop(DesignTokens.Colors.peachLight, DesignTokens.Colors.peach)
        rect(box(62, 6, 38, 74), Paint.woodDark)
        let spines: [Color] = [DesignTokens.Colors.primary, DesignTokens.Colors.accent, DesignTokens.Colors.warning,
                               DesignTokens.Colors.background, DesignTokens.Colors.accentHover]
        for row in 0..<3 {
            let y = 10 + CGFloat(row) * 22
            rect(box(64, y + 16, 34, 2), Paint.wood)
            var x: CGFloat = 65
            for i in 0..<6 {
                let w: CGFloat = 4 + CGFloat((i * 7 + row * 3) % 3)
                let h: CGFloat = 11 + CGFloat((i * 5 + row) % 4)
                rect(box(x, y + 16 - h, w, h), spines[(i + row * 2) % spines.count], radius: 0.6)
                x += w + 1
            }
        }
        desk()
        lamp(at: 22)
        rect(box(42, 68, 11, 10), DesignTokens.Colors.primary, radius: 2)
        rect(box(52, 70, 4, 5), DesignTokens.Colors.primary, radius: 2, opacity: 0.8)
    }

    private mutating func movies() {
        backdrop(Paint.night, Paint.nightDeep)
        rect(box(0, 0, 11, 64), Paint.curtain)
        rect(box(89, 0, 11, 64), Paint.curtain)
        let pulse = 0.88 + 0.1 * sin(t * 1.7)
        glow(pt(50, 30), 46, DesignTokens.Colors.heatOrange, opacity: 0.35 * pulse)
        context.fill(Path(roundedRect: box(15, 12, 70, 36), cornerRadius: 3 * unit),
                     with: .linearGradient(Gradient(colors: [DesignTokens.Colors.peachLight.opacity(pulse), DesignTokens.Colors.warning.opacity(pulse)]),
                                           startPoint: pt(15, 12), endPoint: pt(85, 48)))
        // A small figure on the horizon, so the screen reads as a film and not a panel.
        poly([pt(46, 40), pt(50, 24), pt(54, 40)], Paint.nightDeep, opacity: 0.55)
        for row in 0..<2 {
            let y = 66 + CGFloat(row) * 14
            for i in 0..<5 {
                let x = 10 + CGFloat(i) * 20 + (row == 1 ? 10 : 0)
                disc(pt(x, y - 1), 4.6, Paint.ink)
                rect(box(x - 8, y + 3, 16, 24), Paint.seatRed, radius: 4)
            }
        }
    }

    private mutating func concert() {
        backdrop(Paint.stageTop, Paint.stageBottom)
        for i in 0..<3 {
            let apex = pt(28 + CGFloat(i) * 22, 0)
            let sweep = 0.42 * sin(t * 1.25 + Double(i) * 1.3)
            let foot = CGPoint(x: apex.x + CGFloat(sin(sweep)) * 70 * unit, y: 72 * unit)
            poly([apex, CGPoint(x: foot.x - 9 * unit, y: foot.y), CGPoint(x: foot.x + 9 * unit, y: foot.y)],
                 i == 1 ? DesignTokens.Colors.peachLight : DesignTokens.Colors.warning, opacity: 0.3)
        }
        glow(pt(50, 78), 40, DesignTokens.Colors.primary, opacity: 0.55)
        for i in 0..<7 {
            let x = 4 + CGFloat(i) * 15
            let bob = CGFloat(sin(t * 3 + Double(i) * 1.7)) * 1.4
            disc(pt(x, 84 + bob), 6.2, Paint.ink)
            rect(box(x - 8, 88 + bob, 16, 20), Paint.ink, radius: 6)
            if i % 2 == 0 { rect(box(x + 4, 70 + bob - CGFloat(sin(t * 3 + Double(i))) * 2, 2.6, 14), Paint.ink, radius: 1.3) }
        }
    }

    private mutating func gym() {
        backdrop(DesignTokens.Colors.background, DesignTokens.Colors.peachLight)
        rect(box(56, 8, 38, 46), Paint.sky, radius: 2)
        rect(box(74, 8, 2.4, 46), DesignTokens.Colors.background)
        rect(box(56, 28, 38, 2.4), DesignTokens.Colors.background)
        poly([pt(56, 54), pt(94, 54), pt(70, 82), pt(30, 82)], DesignTokens.Colors.warning, opacity: 0.2)
        rect(CGRect(x: 0, y: 80 * unit, width: size.width, height: size.height - 80 * unit), Color(hex: "#D9B28A"))
        rect(box(14, 70, 38, 3.4), Paint.woodDark, radius: 1.7)
        for x in [10.0, 15.0, 46.0, 51.0] {
            let big = x == 10 || x == 51
            rect(box(CGFloat(x), big ? 61 : 64, 4, big ? 22 : 16), DesignTokens.Colors.accentHover, radius: 1.5)
        }
        disc(pt(76, 74), 9, Paint.woodDark)
        var handle = Path()
        handle.addArc(center: pt(76, 66), radius: 6 * unit, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        context.stroke(handle, with: .color(Paint.woodDark), style: StrokeStyle(lineWidth: 2.2 * unit, lineCap: .round))
    }

    private mutating func cooking() {
        backdrop(DesignTokens.Colors.peachLight, DesignTokens.Colors.peach)
        var tiles = Path()
        for i in 0...10 {
            tiles.move(to: CGPoint(x: 0, y: CGFloat(i) * 14 * unit)); tiles.addLine(to: CGPoint(x: size.width, y: CGFloat(i) * 14 * unit))
        }
        var x: CGFloat = originX - 70 * unit
        while x < size.width { tiles.move(to: CGPoint(x: x, y: 0)); tiles.addLine(to: CGPoint(x: x, y: 74 * unit)); x += 14 * unit }
        context.stroke(tiles, with: .color(DesignTokens.Colors.accentSoft), lineWidth: 1.4)
        rect(CGRect(x: 0, y: 74 * unit, width: size.width, height: size.height - 74 * unit), Paint.counter)
        rect(box(10, 70, 80, 5), Paint.ink, radius: 1.5)
        rect(box(24, 50, 40, 22), DesignTokens.Colors.primary, radius: 4)
        rect(box(21, 45, 46, 7), DesignTokens.Colors.primary.opacity(0.78), radius: 3)
        disc(pt(44, 44), 3, DesignTokens.Colors.primary.opacity(0.78))
        rect(box(64, 56, 9, 3), DesignTokens.Colors.primary, radius: 1.5)
        for i in 0..<3 {
            var steam = Path()
            let base = 34 + CGFloat(i) * 10
            let rise = CGFloat((t * 9 + Double(i) * 11).truncatingRemainder(dividingBy: 14))
            steam.move(to: pt(base, 42))
            for step in stride(from: CGFloat(0), through: 28, by: 4) {
                steam.addLine(to: pt(base + 3 * CGFloat(sin(Double(step) * 0.25 + t * 2.2 + Double(i))), 42 - step - rise * 0.4))
            }
            context.stroke(steam, with: .color(DesignTokens.Colors.background.opacity(0.75)), style: StrokeStyle(lineWidth: 2.6 * unit, lineCap: .round, lineJoin: .round))
        }
        for (cx, r) in [(78.0, 9.0), (92.0, 7.0)] {
            disc(pt(CGFloat(cx), 22), CGFloat(r), Paint.ink)
            rect(box(CGFloat(cx) - 1, 4, 2, 9), Paint.ink)
        }
    }

    private mutating func flying() {
        backdrop(Paint.sky, DesignTokens.Colors.peachLight)
        for i in 0..<3 {
            let speed = 5.0 + Double(i) * 3
            let x = CGFloat((Double(i) * 37 + t * speed).truncatingRemainder(dividingBy: 130)) - 15
            let y = 22 + CGFloat(i) * 22
            for (dx, dy, r) in [(-7.0, 2.0, 7.0), (0.0, -2.0, 9.0), (8.0, 2.0, 7.0)] {
                disc(pt(x + CGFloat(dx), y + CGFloat(dy)), CGFloat(r), .white, opacity: 0.92)
            }
        }
        var plane = context
        plane.translateBy(x: pt(56, 40).x, y: pt(56, 40).y)
        plane.rotate(by: .degrees(-9))
        plane.fill(Path(roundedRect: CGRect(x: -13 * unit, y: -2.4 * unit, width: 26 * unit, height: 4.8 * unit), cornerRadius: 2.4 * unit), with: .color(DesignTokens.Colors.accentHover))
        plane.fill(Path { p in
            p.move(to: CGPoint(x: -2 * unit, y: 0)); p.addLine(to: CGPoint(x: -9 * unit, y: 11 * unit)); p.addLine(to: CGPoint(x: 2 * unit, y: 0)); p.closeSubpath()
        }, with: .color(DesignTokens.Colors.accentHover))
        plane.fill(Path { p in
            p.move(to: CGPoint(x: -11 * unit, y: -1 * unit)); p.addLine(to: CGPoint(x: -14 * unit, y: -7 * unit)); p.addLine(to: CGPoint(x: -8 * unit, y: -1 * unit)); p.closeSubpath()
        }, with: .color(DesignTokens.Colors.accentHover))
        // The window: a cream frame around the hero, so it reads as looking out of a plane.
        let frame = Path(roundedRect: box(14, 6, 72, 88), cornerRadius: 22 * unit)
        context.stroke(frame, with: .color(DesignTokens.Colors.background), lineWidth: 5 * unit)
        context.stroke(frame, with: .color(DesignTokens.Colors.border), lineWidth: 1)
    }

    private mutating func studying() {
        backdrop(Color(hex: "#F3D9BC"), Color(hex: "#E8BF93"))
        desk()
        lamp(at: 24)
        let books: [(CGFloat, CGFloat, Color)] = [(64, 50, DesignTokens.Colors.accentHover), (60, 54, DesignTokens.Colors.primary), (58, 46, DesignTokens.Colors.warning), (56, 42, DesignTokens.Colors.background)]
        var y: CGFloat = 78
        for (w, _, color) in books {
            y -= 8
            rect(box(86 - w * 0.62, y, w * 0.62, 8), color, radius: 1.2)
            rect(box(86 - w * 0.62 + 2, y + 2.4, w * 0.62 - 4, 1.2), DesignTokens.Colors.background, opacity: 0.55)
        }
    }

    private mutating func napping() {
        backdrop(Paint.night, Paint.nightDeep)
        for i in 0..<8 {
            let x = CGFloat((i * 37 + 11) % 100)
            let y = CGFloat((i * 23 + 7) % 56)
            let twinkle = 0.45 + 0.45 * sin(t * 1.5 + Double(i) * 1.9)
            disc(pt(x, y), 0.9 + CGFloat(i % 3) * 0.3, DesignTokens.Colors.peachLight, opacity: twinkle)
        }
        context.drawLayer { layer in
            let bite = Path(ellipseIn: CGRect(x: pt(72, 22).x - 12 * unit, y: 22 * unit - 12 * unit, width: 24 * unit, height: 24 * unit))
            layer.clip(to: bite, options: .inverse)
            layer.fill(Path(ellipseIn: CGRect(x: pt(66, 28).x - 15 * unit, y: 28 * unit - 15 * unit, width: 30 * unit, height: 30 * unit)),
                       with: .color(DesignTokens.Colors.peachLight))
        }
        rect(box(10, 72, 66, 22), DesignTokens.Colors.border, radius: 9)
        rect(box(10, 68, 66, 22), DesignTokens.Colors.background, radius: 9)
        rect(box(16, 73, 54, 2.2), DesignTokens.Colors.peach, radius: 1.1, opacity: 0.6)
    }

    private mutating func free() {
        backdrop(DesignTokens.Colors.peachLight, DesignTokens.Colors.background)
        let center = pt(50, 40)
        var rays = Path()
        for i in 0..<12 {
            let a = Double(i) / 12 * 2 * .pi + t * 0.25
            rays.move(to: CGPoint(x: center.x + CGFloat(cos(a)) * 23 * unit, y: center.y + CGFloat(sin(a)) * 23 * unit))
            rays.addLine(to: CGPoint(x: center.x + CGFloat(cos(a)) * 32 * unit, y: center.y + CGFloat(sin(a)) * 32 * unit))
        }
        context.stroke(rays, with: .color(DesignTokens.Colors.warning), style: StrokeStyle(lineWidth: 2.6 * unit, lineCap: .round))
        glow(center, 30, DesignTokens.Colors.warning, opacity: 0.35)
        disc(center, 17, DesignTokens.Colors.warning)
        context.fill(Path(ellipseIn: box(-20, 74, 96, 60)), with: .color(DesignTokens.Colors.accent))
        context.fill(Path(ellipseIn: box(30, 82, 90, 56)), with: .color(DesignTokens.Colors.accentHover))
    }

    // MARK: Pokes

    private mutating func ring(_ c: CGPoint, _ r: CGFloat, _ color: Color, width: CGFloat, opacity: Double = 1) {
        let rr = r * unit
        context.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)),
                       with: .color(color.opacity(opacity)), lineWidth: width * unit)
    }

    /// A tap on warm paper: three coral ripples leaving one ember dot. Still, they sit at even radii.
    private mutating func poke() {
        backdrop(DesignTokens.Colors.peachLight, DesignTokens.Colors.background)
        let c = pt(50, 50)
        let reach: Double = 42
        for i in 0..<3 {
            let r = (Double(i) * reach / 3 + t * 7).truncatingRemainder(dividingBy: reach)
            ring(c, 8 + CGFloat(r), DesignTokens.Colors.primary, width: 2.4, opacity: 0.85 * (1 - r / reach))
        }
        glow(c, 22, DesignTokens.Colors.primary, opacity: 0.3)
        disc(c, 7, DesignTokens.Colors.primary)
    }

    /// The same dot, landed: a calm teal ring and a tick. No motion; the moment has passed.
    private mutating func pokeSeen() {
        backdrop(DesignTokens.Colors.accentSoft, DesignTokens.Colors.background)
        let c = pt(50, 50)
        ring(c, 27, DesignTokens.Colors.accent, width: 2.4, opacity: 0.55)
        disc(c, 19, DesignTokens.Colors.surface)
        ring(c, 19, DesignTokens.Colors.accentHover, width: 2)
        var tick = Path()
        tick.move(to: pt(41, 50))
        tick.addLine(to: pt(47.5, 57))
        tick.addLine(to: pt(60, 43))
        context.stroke(tick, with: .color(DesignTokens.Colors.accentHover), style: StrokeStyle(lineWidth: 3.2 * unit, lineCap: .round, lineJoin: .round))
    }

    /// A trail over the hills to a sun, with two travellers on it: someone is coming with you.
    private mutating func tagAlong() {
        backdrop(Paint.sky, DesignTokens.Colors.background)
        glow(pt(78, 26), 24, DesignTokens.Colors.warning, opacity: 0.45)
        disc(pt(78, 26), 11, DesignTokens.Colors.warning)
        context.fill(Path(ellipseIn: box(-24, 62, 104, 70)), with: .color(DesignTokens.Colors.accent))
        context.fill(Path(ellipseIn: box(34, 72, 96, 62)), with: .color(DesignTokens.Colors.accentHover))
        var trail = Path()
        trail.move(to: pt(8, 88))
        trail.addCurve(to: pt(70, 40), control1: pt(34, 86), control2: pt(38, 46))
        context.stroke(trail, with: .color(DesignTokens.Colors.surface.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 2.2 * unit, lineCap: .round, dash: [4 * unit, 5 * unit], dashPhase: -CGFloat(t) * 6 * unit))
        disc(pt(46, 62), 6.5, DesignTokens.Colors.surface)
        disc(pt(46, 62), 5, DesignTokens.Colors.primary)
        disc(pt(31, 76), 5.5, DesignTokens.Colors.surface)
        disc(pt(31, 76), 4, DesignTokens.Colors.text)
    }

    private mutating func quiet() {
        backdrop(DesignTokens.Colors.background, DesignTokens.Colors.peachLight)
        let c = pt(50, 50)
        let circle = Path(ellipseIn: CGRect(x: c.x - 24 * unit, y: c.y - 24 * unit, width: 48 * unit, height: 48 * unit))
        context.stroke(circle, with: .color(DesignTokens.Colors.peach), style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
        disc(c, 3.2, DesignTokens.Colors.peach)
    }
}

#Preview("Scenes") {
    let styles: [SceneStyle] = StatusKind.allCases.map { .status($0) } + [.busy, .quiet, .poke, .pokeSeen, .tagAlong]
    return ScrollView {
        VStack(spacing: 8) {
            ForEach(Array(styles.enumerated()), id: \.offset) { _, style in
                SceneArt(style: style, anchor: 0.3)
                    .frame(height: 104)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
            }
        }
        .padding(20)
    }
    .background(DesignTokens.Colors.background)
}
