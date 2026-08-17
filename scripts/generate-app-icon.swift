// Renders macos/DSHApp/AppIcon.icns from code so the icon stays editable
// alongside the jelly-sea theme (colors mirror DSHTheme's accent family).
// Run via scripts/generate-app-icon.sh; not part of the app target.
import AppKit

let canvas: CGFloat = 1024
// Big Sur icon grid: 824pt squircle centered in a 1024 canvas.
let inset: CGFloat = 100
let corner: CGFloat = 185

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
  NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

let squircle = NSBezierPath(
  roundedRect: NSRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2),
  xRadius: corner, yRadius: corner)
squircle.addClip()

// Deep-sea vertical gradient: DSHTheme dark canvas up top, accent teal below.
let background = NSGradient(colors: [
  color(0.031, 0.106, 0.125),
  color(0.043, 0.216, 0.235),
  color(0.039, 0.424, 0.404),
])!
background.draw(in: NSRect(x: 0, y: 0, width: canvas, height: canvas), angle: -90)

// Soft aqua halo centered on the moon — start at radius 0 or the unpainted
// inner disc shows through as a dark circle.
let moonCenter = NSPoint(x: canvas * 0.658, y: canvas * 0.758)
let glow = NSGradient(starting: color(0.427, 0.898, 0.847, 0.30), ending: color(0.427, 0.898, 0.847, 0))!
glow.draw(fromCenter: moonCenter, radius: 0, toCenter: moonCenter, radius: 430, options: [])

// Pearl / moon.
let pearlRect = NSRect(x: moonCenter.x - 59, y: moonCenter.y - 59, width: 118, height: 118)
color(0.867, 0.980, 0.960, 0.95).setFill()
NSBezierPath(ovalIn: pearlRect).fill()

/// One wave band: a filled region whose top edge is a two-crest cosine curve.
func wave(baseY: CGFloat, amplitude: CGFloat, phase: CGFloat, _ fill: NSColor) {
  let path = NSBezierPath()
  path.move(to: NSPoint(x: 0, y: 0))
  path.line(to: NSPoint(x: 0, y: baseY + amplitude * cos(phase)))
  let steps = 64
  for i in 0...steps {
    let x = CGFloat(i) / CGFloat(steps) * canvas
    let y = baseY + amplitude * cos(phase + CGFloat(i) / CGFloat(steps) * .pi * 2 * 1.25)
    path.line(to: NSPoint(x: x, y: y))
  }
  path.line(to: NSPoint(x: canvas, y: 0))
  path.close()
  fill.setFill()
  path.fill()
}

wave(baseY: canvas * 0.52, amplitude: 46, phase: 0.6, color(0.290, 0.871, 0.824, 0.16))
wave(baseY: canvas * 0.44, amplitude: 52, phase: 2.2, color(0.290, 0.871, 0.824, 0.30))
wave(baseY: canvas * 0.36, amplitude: 58, phase: 4.1, color(0.376, 0.925, 0.871, 0.55))
wave(baseY: canvas * 0.28, amplitude: 50, phase: 5.6, color(0.173, 0.773, 0.722, 0.95))

image.unlockFocus()
_ = ctx

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("png encode failed") }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
