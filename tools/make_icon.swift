// 生成 App 图标：swift tools/make_icon.swift raw.png，再用 sips 转 jpeg→png 去掉透明通道（App Store 要求）
import AppKit
let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let cs = CGColorSpaceCreateDeviceRGB()
func c(_ r: CGFloat,_ g: CGFloat,_ b: CGFloat,_ a: CGFloat = 1) -> CGColor { CGColor(red: r/255, green: g/255, blue: b/255, alpha: a) }
let mint = c(0, 230, 200), cyan = c(60, 190, 255)
// 背景：深色径向渐变（手表会裁成圆形）
let bg = CGGradient(colorsSpace: cs, colors: [c(16, 44, 48), c(4, 10, 14)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(bg, startCenter: CGPoint(x: S/2, y: S/2), startRadius: 0, endCenter: CGPoint(x: S/2, y: S/2), endRadius: S*0.72, options: [])
let grad = CGGradient(colorsSpace: cs, colors: [mint, cyan] as CFArray, locations: [0, 1])!
func strokeGradient(_ path: CGPath, width: CGFloat, glow: Bool) {
    ctx.saveGState()
    if glow { ctx.setShadow(offset: .zero, blur: 50, color: c(0, 230, 210, 0.75)) }
    ctx.addPath(path); ctx.setLineWidth(width); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])
    ctx.restoreGState()
}
// 圆环：留一个缺口，像「流动」
let ring = CGMutablePath()
ring.addArc(center: CGPoint(x: S/2, y: S/2), radius: S*0.33, startAngle: -.pi*0.18, endAngle: -.pi*0.32 + 2 * .pi, clockwise: false)
// 心跳线
let ecg = CGMutablePath()
let y = S/2, x0 = S*0.24, x1 = S*0.76
ecg.move(to: CGPoint(x: x0, y: y))
ecg.addLine(to: CGPoint(x: S*0.40, y: y))
ecg.addLine(to: CGPoint(x: S*0.45, y: y + S*0.08))
ecg.addLine(to: CGPoint(x: S*0.52, y: y - S*0.17))
ecg.addLine(to: CGPoint(x: S*0.58, y: y + S*0.20))
ecg.addLine(to: CGPoint(x: S*0.63, y: y))
ecg.addLine(to: CGPoint(x: x1, y: y))
// 底层发光
for (p, w) in [(ring as CGPath, S*0.075), (ecg as CGPath, S*0.05)] { strokeGradient(p, width: w, glow: true) }
for (p, w) in [(ring as CGPath, S*0.075), (ecg as CGPath, S*0.05)] { strokeGradient(p, width: w, glow: false) }
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
