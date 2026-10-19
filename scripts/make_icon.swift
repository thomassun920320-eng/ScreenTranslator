// 產生 App 圖示：swift scripts/make_icon.swift <輸出 1024px PNG 路徑>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpaceCreateDeviceRGB()

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }

// 1. macOS 圖示網格：824px 圓角方形，留陰影空間
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(color(0.2, 0.2, 0.5)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [color(0.33, 0.30, 0.98), color(0.58, 0.27, 0.95), color(0.10, 0.72, 0.93)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
// 頂部柔光
let glow = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.28), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 360, y: 860), startRadius: 0, endCenter: CGPoint(x: 360, y: 860), endRadius: 620, options: [])
ctx.restoreGState()

// 2. 掃描框四角（代表擷取畫面）
ctx.saveGState()
ctx.setStrokeColor(color(1, 1, 1, 0.55)); ctx.setLineWidth(26); ctx.setLineCap(.round); ctx.setLineJoin(.round)
let inset: CGFloat = 215, arm: CGFloat = 105
let lo = inset, hi = size - inset
for (x, y, dx, dy) in [(lo, hi, 1.0, -1.0), (hi, hi, -1.0, -1.0), (lo, lo, 1.0, 1.0), (hi, lo, -1.0, 1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
    ctx.move(to: CGPoint(x: x, y: y + dy * arm)); ctx.addLine(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x + dx * arm, y: y))
}
ctx.strokePath()
ctx.restoreGState()

// 3. 兩個重疊的對話泡泡：「A」→「文」
func bubble(_ rect: CGRect, tailLeft: Bool) -> CGPath {
    let p = CGMutablePath()
    p.addRoundedRect(in: rect, cornerWidth: 62, cornerHeight: 62)
    let tx = tailLeft ? rect.minX + 70 : rect.maxX - 70
    p.move(to: CGPoint(x: tx - 34, y: rect.minY + 4))
    p.addLine(to: CGPoint(x: tx + (tailLeft ? -26 : 26), y: rect.minY - 58))
    p.addLine(to: CGPoint(x: tx + 34, y: rect.minY + 4))
    p.closeSubpath()
    return p
}

func drawText(_ string: String, in rect: CGRect, font: NSFont, color: NSColor) {
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
    let s = NSAttributedString(string: string, attributes: attrs)
    let h = s.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin]).height
    s.draw(in: CGRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h))
}

// 後方泡泡（原文，半透明）
let backRect = CGRect(x: 268, y: 470, width: 300, height: 255)
ctx.saveGState()
ctx.addPath(bubble(backRect, tailLeft: true)); ctx.setFillColor(color(1, 1, 1, 0.26)); ctx.fillPath()
ctx.addPath(bubble(backRect, tailLeft: true)); ctx.setStrokeColor(color(1, 1, 1, 0.5)); ctx.setLineWidth(5); ctx.strokePath()
ctx.restoreGState()
let roundedFont: (CGFloat, NSFont.Weight) -> NSFont = { size, weight in
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
}
drawText("A", in: backRect.offsetBy(dx: 0, dy: 8), font: roundedFont(190, .heavy), color: NSColor(white: 1, alpha: 0.95))

// 前方泡泡（譯文，白色實心）
let frontRect = CGRect(x: 448, y: 300, width: 318, height: 270)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0.12, 0.05, 0.35, 0.45))
ctx.addPath(bubble(frontRect, tailLeft: false)); ctx.setFillColor(color(1, 1, 1)); ctx.fillPath()
ctx.restoreGState()
drawText("文", in: frontRect.offsetBy(dx: 0, dy: 6), font: NSFont(name: "PingFangTC-Semibold", size: 178) ?? NSFont.systemFont(ofSize: 178, weight: .bold),
         color: NSColor(calibratedRed: 0.40, green: 0.28, blue: 0.96, alpha: 1))

// 4. 右上角小星芒（AI 翻譯）
func sparkle(center c: CGPoint, r: CGFloat) {
    let p = CGMutablePath(); let k: CGFloat = 0.22
    p.move(to: CGPoint(x: c.x, y: c.y + r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + r * k, y: c.y + r * k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + r * k, y: c.y - r * k))
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - r * k, y: c.y - r * k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - r * k, y: c.y + r * k))
    ctx.addPath(p); ctx.setFillColor(color(1, 1, 1, 0.95)); ctx.fillPath()
}
sparkle(center: CGPoint(x: 712, y: 690), r: 52)
sparkle(center: CGPoint(x: 778, y: 610), r: 24)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
