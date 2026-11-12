// Draws the DMG window background (600 x 400 pt, saved at 2x) with the install instruction.
// Usage: swift scripts/make-dmg-background.swift <output.png>
// System frameworks only; draws text and shapes, reads and downloads nothing.
import AppKit

guard CommandLine.arguments.count == 2 else {
  FileHandle.standardError.write(Data("usage: make-dmg-background.swift <output.png>\n".utf8))
  exit(2)
}

let points = NSSize(width: 600, height: 400)
let scale = 2
guard
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(points.width) * scale, pixelsHigh: Int(points.height) * scale,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
  let context = NSGraphicsContext(bitmapImageRep: rep)
else { exit(1) }
rep.size = points  // 1200 x 800 pixels shown at 600 x 400 pt (144 dpi)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))  // draw in points

NSGradient(
  starting: NSColor(calibratedWhite: 0.98, alpha: 1), ending: NSColor(calibratedWhite: 0.88, alpha: 1)
)?.draw(in: NSRect(origin: .zero, size: points), angle: 270)

func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centerY: CGFloat) {
  let paragraph = NSMutableParagraphStyle()
  paragraph.alignment = .center
  let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: size, weight: weight),
    .foregroundColor: color,
    .paragraphStyle: paragraph,
  ]
  let rect = NSRect(x: 20, y: centerY - size, width: points.width - 40, height: size * 2)
  text.draw(in: rect, withAttributes: attributes)
}

draw(
  "Arraste o Volume Manager para Aplicativos", size: 22, weight: .semibold,
  color: NSColor(calibratedWhite: 0.15, alpha: 1), centerY: 335)

// Arrow between the two icons (app at x=150, Applications at x=450, both at y=190 from the top).
let arrowY: CGFloat = 400 - 190
let arrow = NSBezierPath()
arrow.lineWidth = 6
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 235, y: arrowY))
arrow.line(to: NSPoint(x: 365, y: arrowY))
arrow.move(to: NSPoint(x: 340, y: arrowY + 22))
arrow.line(to: NSPoint(x: 368, y: arrowY))
arrow.line(to: NSPoint(x: 340, y: arrowY - 22))
NSColor(calibratedWhite: 0.45, alpha: 1).setStroke()
arrow.stroke()

draw(
  "Na primeira vez: Ajustes do Sistema › Privacidade e Segurança › Abrir Mesmo Assim",
  size: 12, weight: .regular, color: NSColor(calibratedWhite: 0.3, alpha: 1), centerY: 45)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do {
  try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
} catch {
  FileHandle.standardError.write(Data("cannot write image: \(error)\n".utf8))
  exit(1)
}
