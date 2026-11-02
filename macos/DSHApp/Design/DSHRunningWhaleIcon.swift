import AppKit
import SwiftUI

/// The transcript's running icon: the same frame as `SeaWhaleScene`, moved by
/// Core Animation. A `TimelineView` re-rendered the scene on the main thread 20
/// times a second, which cost as much as the old activity line (3.5% against
/// 3.0% in one harness, 2026-11-02).
struct DSHRunningWhaleIcon: View {
  var size: CGFloat = 18
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    DSHRunningWhaleLayer(moving: !reduceMotion, size: size)
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

private struct DSHRunningWhaleLayer: NSViewRepresentable {
  let moving: Bool
  let size: CGFloat

  func makeNSView(context: Context) -> DSHRunningWhaleView { DSHRunningWhaleView() }

  func updateNSView(_ view: DSHRunningWhaleView, context: Context) {
    view.configure(moving: moving, size: size)
  }
}

final class DSHRunningWhaleView: NSView {
  /// The 26pt canvas the transcript gives `SeaWhaleScene`.
  private static let side: CGFloat = 26
  private static let cornerRadius: CGFloat = 6.5
  private static let rollKey = "roll"
  private static let breachKey = "breach"
  private static let breach: CAKeyframeAnimation = {
    let steps = 64
    let animation = CAKeyframeAnimation(keyPath: "transform")
    animation.values = (0...steps).map { step in
      NSValue(caTransform3D: whaleTransform(at: SeaArt.breachPeriod * Double(step) / Double(steps)))
    }
    animation.duration = SeaArt.breachPeriod
    animation.repeatCount = .infinity
    animation.isRemovedOnCompletion = false
    return animation
  }()

  private let scene = CALayer()
  private let whale = CALayer()
  private var waves: [(layer: CAShapeLayer, wave: SeaArt.Wave)] = []
  private var moving = false
  private var size: CGFloat = 18

  var isAnimating: Bool {
    whale.animation(forKey: Self.breachKey) != nil
      && waves.allSatisfy { $0.layer.animation(forKey: Self.rollKey) != nil }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.addSublayer(scene)
    buildScene()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  func configure(moving: Bool, size: CGFloat) {
    self.moving = moving
    self.size = size
    applyScene()
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    applyScene()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyScene()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    applyScene()
  }

  private static func whaleTransform(at time: Double) -> CATransform3D {
    let k = side / 44
    let motion = SeaArt.breach(at: time)
    let y = (SeaArt.whaleRestY - SeaArt.whaleTravel * motion.lift) * k
    return CATransform3DRotate(
      CATransform3DMakeTranslation(motion.dx * k, y, 0),
      motion.tilt * .pi / 180, 0, 0, 1)
  }

  private func buildScene() {
    let side = Self.side
    let canvas = CGRect(x: 0, y: 0, width: side, height: side)
    scene.bounds = canvas
    scene.isGeometryFlipped = true
    scene.masksToBounds = true
    scene.cornerRadius = Self.cornerRadius
    scene.cornerCurve = .continuous

    let sky = CAGradientLayer()
    sky.frame = canvas
    sky.colors = [NSColor(SeaArt.skyTop).cgColor, NSColor(SeaArt.skyBottom).cgColor]
    sky.startPoint = CGPoint(x: 0.5, y: 0)
    sky.endPoint = CGPoint(x: 0.5, y: 1)
    scene.addSublayer(sky)

    let far = waveLayer(SeaArt.farWave)
    let mid = waveLayer(SeaArt.midWave)
    let near = waveLayer(SeaArt.nearWave)
    buildWhale()
    [far, whale, mid, near].forEach(scene.addSublayer)
    waves = [(far, SeaArt.farWave), (mid, SeaArt.midWave), (near, SeaArt.nearWave)]
  }

  /// One band a wavelength wider than the canvas: sliding it left by exactly a
  /// wavelength looks the same as advancing `WaveBand.phase` by a full cycle.
  private func waveLayer(_ wave: SeaArt.Wave) -> CAShapeLayer {
    let band = WaveBand(baseY: wave.baseY, amplitude: wave.amplitude, phase: wave.phase(at: 0))
    let long = WaveBand(
      baseY: wave.baseY, amplitude: wave.amplitude, phase: wave.phase(at: 0), freq: band.freq + 1)
    let layer = CAShapeLayer()
    layer.frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
    layer.path = long.path(
      in: CGRect(x: 0, y: 0, width: Self.side * long.freq / band.freq, height: Self.side)
    ).cgPath
    layer.fillColor = NSColor(wave.color).withAlphaComponent(wave.alpha).cgColor
    return layer
  }

  private func buildWhale() {
    let box = SeaArt.whaleSize * Self.side / 44
    let rect = CGRect(x: 0, y: 0, width: box, height: box)
    let eye = box * 0.052
    let eyeRect = CGRect(x: box * 0.82 - eye / 2, y: box * 0.37 - eye / 2, width: eye, height: eye)
    let parts: [(Path, Color)] = [
      (WhaleBody().path(in: rect), SeaArt.whaleInk),
      (WhaleFluke().path(in: rect), SeaArt.whaleInk),
      (WhaleMouth().path(in: rect), SeaArt.skyTop),
      (Path(ellipseIn: eyeRect), SeaArt.skyTop),
    ]
    whale.bounds = rect
    whale.position = CGPoint(x: Self.side / 2, y: Self.side / 2)
    whale.transform = Self.whaleTransform(at: 0)
    for (path, color) in parts {
      let part = CAShapeLayer()
      part.frame = rect
      part.path = path.cgPath
      part.fillColor = NSColor(color).cgColor
      whale.addSublayer(part)
    }
  }

  private func applyScene() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    scene.position = CGPoint(x: bounds.midX, y: bounds.midY)
    scene.setAffineTransform(CGAffineTransform(scaleX: size / Self.side, y: size / Self.side))
    let scale = window?.backingScaleFactor ?? 2
    ([scene, whale] + (scene.sublayers ?? []) + (whale.sublayers ?? [])).forEach {
      $0.contentsScale = scale
    }
    CATransaction.commit()
    guard moving, window != nil else {
      waves.forEach { $0.layer.removeAnimation(forKey: Self.rollKey) }
      whale.removeAnimation(forKey: Self.breachKey)
      return
    }
    for (layer, wave) in waves where layer.animation(forKey: Self.rollKey) == nil {
      let roll = CABasicAnimation(keyPath: "transform.translation.x")
      roll.fromValue = 0
      roll.toValue = -Self.side / WaveBand(baseY: 0, amplitude: 0, phase: 0).freq
      roll.duration = wave.period
      roll.repeatCount = .infinity
      roll.isRemovedOnCompletion = false
      layer.add(roll, forKey: Self.rollKey)
    }
    if whale.animation(forKey: Self.breachKey) == nil {
      whale.add(Self.breach, forKey: Self.breachKey)
    }
  }
}
