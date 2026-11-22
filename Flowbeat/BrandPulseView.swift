import SwiftUI

/// 首页的 Flowbeat 标志，会动：开口的渐变圆环 + 「平线 → 心跳 → 波浪」那条线，
/// 一道亮光像心电图扫描一样从左往右流过（每 2.2 秒一次，接近心跳的节奏）。
///
/// 几何按 docs/brand 里的标志（1344 × 1344 画布）换算成 0…1 的比例：
/// 圆环中心 (0.5, 0.5)、半径 0.428、线宽 0.086，缺口在左上（217.6° → 270°）；
/// 线从 x 0.262 到 0.738，线宽 0.052，颜色 橙 #FF9A3C → 青 #19E6D9 → 蓝 #38D3F5。
/// 「减少动态效果」打开时只画静态标志。
struct BrandPulseView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 一次扫描的周期（秒）和亮光走完全程用的时间
    static let period = 2.2
    static let sweep = 1.5

    var body: some View {
        if reduceMotion {
            Canvas { ctx, size in Self.draw(ctx, size: size, phase: nil) }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
                Canvas { ctx, size in
                    let t = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
                    Self.draw(ctx, size: size, phase: min(1, t / Self.sweep))
                }
            }
        }
    }

    static let orange = Color(red: 1.0, green: 0.604, blue: 0.235)     // #FF9A3C
    static let mint = Color(red: 0.098, green: 0.902, blue: 0.851)     // #19E6D9
    static let blue = Color(red: 0.220, green: 0.827, blue: 0.961)     // #38D3F5

    /// phase: 亮光头部走到哪（0…1）；nil = 静态
    static func draw(_ ctx: GraphicsContext, size: CGSize, phase: Double?) {
        let s = min(size.width, size.height)
        let origin = CGPoint(x: (size.width - s) / 2, y: (size.height - s) / 2)
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: origin.x + x * s, y: origin.y + y * s) }

        // 圆环：缺口（淡）+ 主体（渐变）
        let center = p(0.5, 0.5), r = 0.428 * s
        let ringStyle = StrokeStyle(lineWidth: 0.086 * s, lineCap: .round)
        var gap = Path()
        gap.addArc(center: center, radius: r, startAngle: .degrees(217.6), endAngle: .degrees(270), clockwise: false)
        ctx.stroke(gap, with: .color(mint.opacity(0.18)), style: ringStyle)
        var ring = Path()
        ring.addArc(center: center, radius: r, startAngle: .degrees(-90), endAngle: .degrees(217.6), clockwise: false)
        ctx.stroke(ring, with: .linearGradient(Gradient(colors: [blue, mint]), startPoint: p(0.85, 0.15), endPoint: p(0.15, 0.85)),
                   style: ringStyle)

        // 心跳线
        var line = Path()
        line.move(to: p(0.262, 0.499))
        line.addLine(to: p(0.339, 0.499))
        line.addLine(to: p(0.399, 0.350))
        line.addLine(to: p(0.452, 0.640))
        line.addLine(to: p(0.499, 0.505))
        line.addCurve(to: p(0.648, 0.499), control1: p(0.525, 0.415), control2: p(0.622, 0.415))
        line.addCurve(to: p(0.738, 0.499), control1: p(0.672, 0.565), control2: p(0.718, 0.565))
        let lineStyle = StrokeStyle(lineWidth: 0.052 * s, lineCap: .round, lineJoin: .round)
        let lineShading = GraphicsContext.Shading.linearGradient(
            Gradient(stops: [.init(color: orange, location: 0), .init(color: mint, location: 0.236), .init(color: blue, location: 1)]),
            startPoint: p(0.262, 0.5), endPoint: p(0.738, 0.5))

        guard let phase else {
            ctx.stroke(line, with: lineShading, style: lineStyle)
            return
        }
        // 底线常亮但偏暗，亮光段（尾巴 0.35）沿线流过，带一点辉光
        ctx.stroke(line, with: lineShading, style: lineStyle)
        var dim = ctx
        dim.opacity = 0.55
        dim.stroke(line, with: .color(.black), style: lineStyle)
        let head = phase * 1.35, tail = head - 0.35
        guard head > 0, tail < 1 else { return }
        let lit = line.trimmedPath(from: max(0, tail), to: min(1, head))
        var glow = ctx
        glow.addFilter(.shadow(color: mint.opacity(0.9), radius: 0.05 * s))
        glow.stroke(lit, with: lineShading, style: lineStyle)
        ctx.stroke(lit, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 0.02 * s, lineCap: .round, lineJoin: .round))
    }
}

#Preview {
    BrandPulseView().frame(width: 80, height: 80).padding().background(.black)
}
