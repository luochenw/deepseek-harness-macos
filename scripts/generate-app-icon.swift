// Renders macos/DSHApp/AppIcon.icns from code so the icon stays editable
// alongside the jelly-sea theme.
//
// This is a hand-copied mirror of macos/DSHApp/NativeSeaArt.swift: this script
// is not part of the app target and draws with AppKit, so it cannot import
// SeaArt / WhaleBody. Every constant below has a twin over there — change one,
// change both, or the Dock icon drifts away from the in-app artwork.
// Decision record: .agents/notes/implemented/feature/2026-08-27-bubble-whale-daylight.md
//
// Run via scripts/generate-app-icon.sh.
import AppKit

let canvas: CGFloat = 1024
// Big Sur icon grid: 824pt squircle centered in a 1024 canvas.
let inset: CGFloat = 100
let corner: CGFloat = 185
/// The artwork is authored against the bubble's 44pt canvas, then scaled up.
let side = canvas - inset * 2
let scale = side / 44

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
  NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

// MARK: - Palette (mirrors SeaArt)

let skyTop = color(1.0, 1.0, 0.996)
let skyBottom = color(0.945, 0.980, 0.976)
let waterFar = color(0.62, 0.96, 0.93, 0.34)
let waterMid = color(0.45, 0.92, 0.88, 0.42)
let waterNear = color(0.22, 0.82, 0.78, 0.52)
let whaleInk = color(0.055, 0.235, 0.255)

// MARK: - Scene space
//
// Scene coordinates are the bubble's 44pt canvas with y pointing *down*, same
// as SwiftUI. AppKit's origin is bottom-left, so `point` flips y on the way out.

func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
  NSPoint(x: inset + x * scale, y: inset + (44 - y) * scale)
}

/// One frozen frame of the breach loop. t = 1.8s puts the whale high and
/// nose-up — the most legible pose for a static icon.
let frameTime: Double = 1.8
let cycle = (frameTime / 5.5).truncatingRemainder(dividingBy: 1)
let phase = cycle * .pi * 2
let lift = CGFloat(0.5 - 0.5 * cos(phase))
let tiltDegrees = -22.0 * sin(phase)
let driftX = CGFloat(-2.5 * cos(phase))

let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()
guard NSGraphicsContext.current != nil else { fatalError("no context") }

let squircle = NSBezierPath(
  roundedRect: NSRect(x: inset, y: inset, width: side, height: side),
  xRadius: corner, yRadius: corner)
squircle.addClip()

// Sky.
NSGradient(colors: [skyTop, skyBottom])!
  .draw(in: NSRect(x: 0, y: 0, width: canvas, height: canvas), angle: -90)

/// One wave band: a filled region whose top edge is a clean cosine. Mirrors
/// WaveBand in ConversationView.swift — all three layers share `freq` so the
/// crests stay parallel and evenly spaced; depth comes from baseline, amplitude
/// and speed, not from bending the waveform.
func wave(baseY: CGFloat, amplitude: CGFloat, phase p: CGFloat, _ fill: NSColor) {
  let freq: CGFloat = 1.5
  let path = NSBezierPath()
  path.move(to: point(0, 44))
  let steps = 240
  for i in 0...steps {
    let f = CGFloat(i) / CGFloat(steps)
    let y = baseY * 44 + amplitude * 44 * cos(p + f * .pi * 2 * freq)
    path.line(to: point(f * 44, y))
  }
  path.line(to: point(44, 44))
  path.close()
  fill.setFill()
  path.fill()
}

// MARK: - Whale (mirrors WhaleBody / WhaleFluke / WhaleMouth)

/// Head → tail. Radii carry the thickness, so the head stations are the fattest.
let stations: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [
  (78, 38, 22), (58, 42, 22), (38, 50, 15), (25, 58, 7), (17, 63, 3),
]
/// The whale is drawn in a 19pt box inside the 44pt scene. 26pt spanned nearly
/// six tenths of the diameter and crowded the seascape out.
let whaleBox: CGFloat = 19
let whaleOriginX = (44 - whaleBox) / 2 + driftX
let whaleOriginY = (44 - whaleBox) / 2 + (7.5 - 13.0 * lift)
let whaleCenter = CGPoint(x: whaleOriginX + whaleBox / 2, y: whaleOriginY + whaleBox / 2)
let tilt = tiltDegrees * .pi / 180

/// Local 100×100 whale space → scene space, including the breach rotation.
/// The rotation is applied in y-down scene coordinates so positive degrees read
/// clockwise, matching SwiftUI's `rotationEffect`.
func whalePoint(_ lx: CGFloat, _ ly: CGFloat) -> NSPoint {
  let x = whaleOriginX + lx * whaleBox / 100
  let y = whaleOriginY + ly * whaleBox / 100
  let dx = x - whaleCenter.x, dy = y - whaleCenter.y
  let rx = whaleCenter.x + dx * cos(tilt) - dy * sin(tilt)
  let ry = whaleCenter.y + dx * sin(tilt) + dy * cos(tilt)
  return point(rx, ry)
}

func catmullRom(_ p0: CGFloat, _ p1: CGFloat, _ p2: CGFloat, _ p3: CGFloat, _ t: CGFloat) -> CGFloat {
  let t2 = t * t, t3 = t2 * t
  return 0.5 * ((2 * p1) + (-p0 + p2) * t
    + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
    + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
}

/// Sampled spine: 400 points, not the 120 the app uses — at 1024pt a sparser
/// polyline shows facets along the back.
func spine(samples: Int = 400) -> [(center: CGPoint, radius: CGFloat)] {
  let s = stations
  let perSegment = max(samples / (s.count - 1), 2)
  var out: [(CGPoint, CGFloat)] = []
  for segment in 0..<(s.count - 1) {
    let i0 = max(segment - 1, 0), i1 = segment
    let i2 = segment + 1, i3 = min(segment + 2, s.count - 1)
    for step in 0...perSegment {
      if segment > 0 && step == 0 { continue }
      let t = CGFloat(step) / CGFloat(perSegment)
      out.append((
        CGPoint(x: catmullRom(s[i0].x, s[i1].x, s[i2].x, s[i3].x, t),
                y: catmullRom(s[i0].y, s[i1].y, s[i2].y, s[i3].y, t)),
        max(catmullRom(s[i0].r, s[i1].r, s[i2].r, s[i3].r, t), 0.3)))
    }
  }
  return out.map { (center: $0.0, radius: $0.1) }
}

func whaleBodyPath() -> NSBezierPath {
  let pts = spine()
  var upper: [CGPoint] = [], lower: [CGPoint] = []
  for i in pts.indices {
    let before = pts[max(i - 1, 0)].center
    let after = pts[min(i + 1, pts.count - 1)].center
    var vx = after.x - before.x, vy = after.y - before.y
    let length = max(sqrt(vx * vx + vy * vy), 0.0001)
    vx /= length; vy /= length
    let nx = -vy, ny = vx
    let c = pts[i].center, r = pts[i].radius
    upper.append(CGPoint(x: c.x + nx * r, y: c.y + ny * r))
    lower.append(CGPoint(x: c.x - nx * r, y: c.y - ny * r))
  }
  // Both end caps are traced as arcs of their station circle, sampled in local
  // space so the shared rotation applies uniformly.
  func cap(center: CGPoint, radius: CGFloat, from a0: CGFloat, to a1: CGFloat) -> [CGPoint] {
    let steps = 48
    return (0...steps).map { i in
      let a = a0 + (a1 - a0) * CGFloat(i) / CGFloat(steps)
      return CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
    }
  }
  let head = pts[0]
  let headAngle = atan2(head.center.y - pts[1].center.y, head.center.x - pts[1].center.x)
  let tail = pts[pts.count - 1]
  let tailAngle = atan2(tail.center.y - pts[pts.count - 2].center.y,
                        tail.center.x - pts[pts.count - 2].center.x)

  let path = NSBezierPath()
  path.move(to: whalePoint(upper[0].x, upper[0].y))
  for p in cap(center: head.center, radius: head.radius,
               from: headAngle - .pi / 2, to: headAngle + .pi / 2) {
    path.line(to: whalePoint(p.x, p.y))
  }
  for p in lower.dropFirst() { path.line(to: whalePoint(p.x, p.y)) }
  for p in cap(center: tail.center, radius: tail.radius,
               from: tailAngle + .pi / 2, to: tailAngle - .pi / 2) {
    path.line(to: whalePoint(p.x, p.y))
  }
  for p in upper.reversed().dropFirst() { path.line(to: whalePoint(p.x, p.y)) }
  path.close()
  return path
}

/// SwiftUI 用的是二次贝塞尔，NSBezierPath 只吃三次。正确的升阶是
/// C1 = P0 + 2/3(Q−P0)、C2 = P1 + 2/3(Q−P1)——把两个控制点都填成 Q 会画出
/// 一条不同的曲线，图标上的尾鳍就和 app 里对不上了。
extension NSBezierPath {
  func quadCurve(to end: NSPoint, control q: NSPoint) {
    let p0 = currentPoint
    let c1 = NSPoint(x: p0.x + 2.0 / 3.0 * (q.x - p0.x), y: p0.y + 2.0 / 3.0 * (q.y - p0.y))
    let c2 = NSPoint(x: end.x + 2.0 / 3.0 * (q.x - end.x), y: end.y + 2.0 / 3.0 * (q.y - end.y))
    curve(to: end, controlPoint1: c1, controlPoint2: c2)
  }
}

func whaleFlukePath() -> NSBezierPath {
  let root = CGPoint(x: 17, y: 63)
  let angle: CGFloat = 2.55, span: CGFloat = 23, length: CGFloat = 21
  let ux = cos(angle), uy = sin(angle)
  let nx = -uy, ny = ux
  func q(_ along: CGFloat, _ across: CGFloat) -> NSPoint {
    whalePoint(root.x + ux * along + nx * across, root.y + uy * along + ny * across)
  }
  let path = NSBezierPath()
  path.move(to: q(-2, 3))
  path.quadCurve(to: q(length, span), control: q(length * 0.35, span * 0.85))
  path.quadCurve(to: q(length * 0.42, 2), control: q(length * 0.85, span * 0.30))
  path.quadCurve(to: q(length * 0.98, -span), control: q(length * 0.80, -span * 0.32))
  path.quadCurve(to: q(-2, -3), control: q(length * 0.32, -span * 0.85))
  path.close()
  return path
}

/// The mouth line — a sky-colored arc. This is the stroke that makes the
/// silhouette read as a whale rather than a fish; without it small sizes
/// collapse into a dark blob.
func whaleMouthPath() -> NSBezierPath {
  let path = NSBezierPath()
  path.move(to: whalePoint(96, 44))
  path.quadCurve(to: whalePoint(70, 54), control: whalePoint(83, 52))
  path.quadCurve(to: whalePoint(96, 44), control: whalePoint(83, 54.6))
  path.close()
  return path
}

// Far water sits behind the whale, the two nearer bands in front — so the low
// point of the breach reads as half-submerged.
wave(baseY: 0.60, amplitude: 0.075, phase: CGFloat(frameTime) * 1.6, waterFar)

whaleInk.setFill()
whaleBodyPath().fill()
whaleFlukePath().fill()
skyTop.setFill()
whaleMouthPath().fill()
// Eye: 5.2% of the whale box.
let eyeRadius = whaleBox * 0.052 / 2
let eyeCenter = whalePoint(82, 37)
NSBezierPath(ovalIn: NSRect(x: eyeCenter.x - eyeRadius * scale, y: eyeCenter.y - eyeRadius * scale,
                            width: eyeRadius * 2 * scale, height: eyeRadius * 2 * scale)).fill()

wave(baseY: 0.70, amplitude: 0.065, phase: CGFloat(frameTime) * 2.2 + 2.1, waterMid)
wave(baseY: 0.80, amplitude: 0.055, phase: CGFloat(frameTime) * 2.9 + 4.4, waterNear)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("png encode failed") }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
