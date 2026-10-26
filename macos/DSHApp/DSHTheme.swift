import SwiftUI
import AppKit

/// Brand colors shared by the app chrome, in-app sea artwork, and App Icon.
/// The UI must not introduce another blue family.
enum DSHBrandPalette {
  static let skyTopRGBA: (Double, Double, Double, Double) = (1.0, 1.0, 0.996, 1)
  static let skyBottomRGBA: (Double, Double, Double, Double) = (0.945, 0.980, 0.976, 1)
  static let waterFarRGBA: (Double, Double, Double, Double) = (0.62, 0.96, 0.93, 1)
  static let waterMidRGBA: (Double, Double, Double, Double) = (0.45, 0.92, 0.88, 1)
  static let waterNearRGBA: (Double, Double, Double, Double) = (0.22, 0.82, 0.78, 1)
  static let whaleInkRGBA: (Double, Double, Double, Double) = (0.055, 0.235, 0.255, 1)
  static let rimShadeRGBA: (Double, Double, Double, Double) = (0.04, 0.30, 0.28, 1)

  // Rendered colors sampled from the generated App Icon. UI colors use these
  // resolved values so the app matches the logo users actually see.
  static let logoPrimaryRGBA: (Double, Double, Double, Double) = (
    0xA2 / 255, 0xE4 / 255, 0xE0 / 255, 1)
  static let logoLightRGBA: (Double, Double, Double, Double) = (
    0xC9 / 255, 0xF3 / 255, 0xF0 / 255, 1)
  static let logoNavyRGBA: (Double, Double, Double, Double) = (
    0x24 / 255, 0x4B / 255, 0x51 / 255, 1)

  static let logoPrimary = Color(
    .sRGB,
    red: logoPrimaryRGBA.0,
    green: logoPrimaryRGBA.1,
    blue: logoPrimaryRGBA.2,
    opacity: logoPrimaryRGBA.3)
  static let logoLight = Color(
    .sRGB,
    red: logoLightRGBA.0,
    green: logoLightRGBA.1,
    blue: logoLightRGBA.2,
    opacity: logoLightRGBA.3)
  static let logoNavy = Color(
    .sRGB,
    red: logoNavyRGBA.0,
    green: logoNavyRGBA.1,
    blue: logoNavyRGBA.2,
    opacity: logoNavyRGBA.3)

  static let skyTop = Color(red: skyTopRGBA.0, green: skyTopRGBA.1, blue: skyTopRGBA.2)
  static let skyBottom = Color(
    red: skyBottomRGBA.0,
    green: skyBottomRGBA.1,
    blue: skyBottomRGBA.2)
  static let waterFar = Color(
    red: waterFarRGBA.0,
    green: waterFarRGBA.1,
    blue: waterFarRGBA.2)
  static let waterMid = Color(
    red: waterMidRGBA.0,
    green: waterMidRGBA.1,
    blue: waterMidRGBA.2)
  static let waterNear = Color(
    red: waterNearRGBA.0,
    green: waterNearRGBA.1,
    blue: waterNearRGBA.2)
  static let whaleInk = Color(
    red: whaleInkRGBA.0,
    green: whaleInkRGBA.1,
    blue: whaleInkRGBA.2)
  static let rimShade = Color(
    red: rimShadeRGBA.0,
    green: rimShadeRGBA.1,
    blue: rimShadeRGBA.2)
}

/// Native workbench design tokens — the single source for color, type,
/// radius, spacing, and shared control chrome. The palette keeps one
/// logo-derived blue accent on a cool neutral graphite/porcelain base;
/// decorative gradients and competing tinted surfaces are intentionally
/// avoided so the product reads as one native macOS tool.
enum DSHTheme {
  /// Builds a `Color` that redraws itself from light/dark sRGBA tuples as
  /// the system appearance changes — no Asset Catalog needed (this project
  /// deliberately has no Xcode project; see AGENTS.md). The alpha channel
  /// is load-bearing here: translucency is what makes the jelly look.
  private static func dynamic(light: (Double, Double, Double, Double), dark: (Double, Double, Double, Double)) -> Color {
    Color(NSColor(name: nil) { appearance in
      let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      let c = isDark ? dark : light
      return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
    })
  }

  private static func withAlpha(
    _ color: (Double, Double, Double, Double),
    _ alpha: Double
  ) -> (Double, Double, Double, Double) {
    (color.0, color.1, color.2, alpha)
  }

  // MARK: Text — neutral graphite with a faint blue cast.

  static let ink = dynamic(light: (0.118, 0.137, 0.169, 1), dark: (0.910, 0.929, 0.957, 1))
  static let inkSoft = dynamic(light: (0.322, 0.361, 0.420, 1), dark: (0.682, 0.725, 0.790, 1))
  static let inkFaint = dynamic(light: (0.478, 0.525, 0.596, 1), dark: (0.463, 0.518, 0.596, 1))

  // MARK: Surfaces — neutral and mostly opaque. Depth comes from one clear
  // surface ladder rather than stacked translucent blue washes.

  static let canvas = dynamic(light: (0.959, 0.967, 0.980, 1), dark: (0.075, 0.086, 0.105, 1))
  static let surface = dynamic(light: (1.0, 1.0, 1.0, 0.98), dark: (0.108, 0.126, 0.151, 0.98))
  static let surfaceTint = dynamic(light: (0.929, 0.945, 0.969, 1), dark: (0.143, 0.169, 0.204, 1))
  static let surfaceTint2 = dynamic(light: (0.888, 0.914, 0.949, 1), dark: (0.171, 0.204, 0.247, 1))
  /// Editable controls need stronger separation than passive settings rows.
  static let fieldFill = dynamic(light: (1.0, 1.0, 1.0, 0.99), dark: (0.126, 0.151, 0.184, 1))
  static let fieldStroke = dynamic(light: (0.640, 0.694, 0.772, 0.72), dark: (0.353, 0.412, 0.490, 0.82))

  static let sidebarBg = dynamic(light: (0.929, 0.941, 0.961, 1), dark: (0.090, 0.105, 0.126, 1))
  static let sidebarSelected = dynamic(
    light: DSHBrandPalette.logoPrimaryRGBA,
    dark: DSHBrandPalette.logoNavyRGBA)

  // MARK: Accent — use the rendered logo blue for both emphasis and primary
  // actions. The white foreground is an explicit product requirement.

  static let accent = DSHBrandPalette.logoPrimary
  static let accentBright = DSHBrandPalette.logoPrimary
  static let accentSolid = DSHBrandPalette.logoPrimary
  static let onAccent = Color.white
  static let accentWash = DSHBrandPalette.logoPrimary.opacity(0.16)
  static let accentSoft = DSHBrandPalette.logoPrimary.opacity(0.11)
  static let sessionSelected = DSHBrandPalette.logoPrimary
  static let sessionSelectedForeground = DSHBrandPalette.logoNavy

  // MARK: Semantic — attention / destructive, kept distinct from the accent hue.

  static let warm = dynamic(light: (0.612, 0.416, 0.118, 1), dark: (0.820, 0.647, 0.318, 1))
  static let warmSoft = dynamic(light: (0.612, 0.416, 0.118, 0.12), dark: (0.820, 0.647, 0.318, 0.15))
  static let coral = dynamic(light: (0.678, 0.282, 0.251, 1), dark: (0.827, 0.467, 0.424, 1))
  static let coralSoft = dynamic(light: (0.678, 0.282, 0.251, 0.11), dark: (0.827, 0.467, 0.424, 0.15))
}

/// Compact native-workbench corner radius scale.
enum DSHRadius {
  static let sm: CGFloat = 6
  static let md: CGFloat = 8
  static let lg: CGFloat = 10
  static let xl: CGFloat = 12
}

/// Shared macOS typography roles. Keep body/interface text on SF default;
/// use monospaced type only for code, paths, counts, and terminal data.
enum DSHType {
  static let brand = Font.system(size: 14, weight: .semibold)
  static let display = Font.system(size: 20, weight: .semibold)
  static let pageTitle = Font.system(size: 17, weight: .semibold)
  static let sectionTitle = Font.system(size: 12, weight: .semibold)
  static let body = Font.system(size: 14)
  static let bodyLarge = Font.system(size: 14.5)
  static let label = Font.system(size: 12.5, weight: .medium)
  static let caption = Font.system(size: 11)
  static let micro = Font.system(size: 10.5, weight: .medium)
  static let mono = Font.system(size: 11.5, design: .monospaced)
  static let code = Font.system(size: 12, design: .monospaced)
}

/// Spacing scale in multiples of 4.
enum DSHSpace {
  static let s1: CGFloat = 4
  static let s2: CGFloat = 8
  static let s3: CGFloat = 12
  static let s4: CGFloat = 16
  static let s5: CGFloat = 24
  static let s6: CGFloat = 32
  static let s7: CGFloat = 48
}

// MARK: - Reusable primitives

/// Status indicator dot shared by session rows, subagent rows, and job rows.
struct DSHStatusDot: View {
  enum Kind { case live, unread, idle, success, failure }
  let kind: Kind
  var diameter: CGFloat = 7
  var body: some View {
    Circle().fill(color).frame(width: diameter, height: diameter)
  }
  private var color: Color {
    switch kind {
    case .live: DSHTheme.accent
    case .unread: DSHTheme.warm
    case .idle: .clear
    case .success: DSHTheme.accent
    case .failure: DSHTheme.coral
    }
  }
}

/// Compact live-activity waveform shared by running sessions and tool
/// instructions. Motion communicates ongoing Host work without changing row
/// geometry; Reduce Motion keeps the same shape in a static state.
struct DSHRunningBars: View {
  var color: Color = DSHTheme.warm
  var height: CGFloat = 10
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var moving = false

  private let idleScales: [CGFloat] = [0.52, 0.82, 0.64]
  private let movingScales: [CGFloat] = [1.0, 0.46, 0.84]

  var body: some View {
    HStack(alignment: .center, spacing: 1.5) {
      ForEach(0..<3, id: \.self) { index in
        Capsule()
          .fill(color)
          .frame(width: 2, height: height)
          .scaleEffect(
            y: reduceMotion
              ? 0.72
              : (moving ? movingScales[index] : idleScales[index]),
            anchor: .center)
          .opacity(reduceMotion ? 0.82 : (moving ? 1 : 0.58))
          .animation(
            reduceMotion
              ? nil
              : .easeInOut(duration: 0.58)
                .repeatForever(autoreverses: true)
                .delay(Double(index) * 0.1),
            value: moving)
      }
    }
    .frame(width: 9, height: height)
    .onAppear { moving = !reduceMotion }
    .onChange(of: reduceMotion) { _, reduced in
      moving = !reduced
    }
    .accessibilityHidden(true)
  }
}

/// Small capsule label — exit codes, HTTP status, truncation notices, tags.
struct DSHBadge: View {
  enum Tone { case neutral, accent, warm, coral }
  let text: String
  var tone: Tone = .neutral
  var body: some View {
    Text(text)
      .font(DSHType.micro)
      .padding(.horizontal, DSHSpace.s2).padding(.vertical, 3)
      .background(
        background,
        in: RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous))
      .foregroundStyle(foreground)
  }
  private var background: Color {
    switch tone {
    case .neutral: DSHTheme.surfaceTint2
    case .accent: DSHTheme.accentSoft
    case .warm: DSHTheme.warmSoft
    case .coral: DSHTheme.coralSoft
    }
  }
  private var foreground: Color {
    switch tone {
    case .neutral: DSHTheme.inkSoft
    case .accent: DSHTheme.accent
    case .warm: DSHTheme.warm
    case .coral: DSHTheme.coral
    }
  }
}

/// Shared section label ("工作区", "会话", "运行与工具"…).
struct DSHSectionLabel: ViewModifier {
  func body(content: Content) -> some View {
    content
      .font(DSHType.sectionTitle)
      .foregroundStyle(DSHTheme.inkFaint)
  }
}

/// Field chrome for `TextField`/`SecureField`. A restrained one-point outline
/// makes editable controls recognizable without turning passive content into
/// a field-shaped surface.
struct DSHFieldBackground: ViewModifier {
  var tint: Color = DSHTheme.fieldFill
  var radius: CGFloat = DSHRadius.sm
  func body(content: Content) -> some View {
    content
      .textFieldStyle(.plain)
      .font(DSHType.body)
      .foregroundStyle(DSHTheme.ink)
      .padding(.horizontal, DSHSpace.s3)
      .padding(.vertical, DSHSpace.s2)
      .frame(minHeight: 36)
      .background(tint, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .strokeBorder(DSHTheme.fieldStroke, lineWidth: 1)
      }
  }
}

extension View {
  /// Background-only card chrome — no stroke, no shadow by default. Callers
  /// still own their own internal layout/padding.
  func dshCard(tint: Color = DSHTheme.surface, radius: CGFloat = DSHRadius.md) -> some View {
    background(tint, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
  }
  func dshSectionLabel() -> some View { modifier(DSHSectionLabel()) }
  func dshField(tint: Color = DSHTheme.fieldFill, radius: CGFloat = DSHRadius.sm) -> some View {
    modifier(DSHFieldBackground(tint: tint, radius: radius))
  }
}

// MARK: - Button styles

struct DSHPrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(DSHType.label.weight(.semibold))
      .padding(.horizontal, DSHSpace.s4).padding(.vertical, 10)
      .background(
        DSHTheme.accentSolid,
        in: RoundedRectangle(cornerRadius: DSHRadius.md, style: .continuous))
      .foregroundStyle(DSHTheme.onAccent)
      .overlay {
        RoundedRectangle(cornerRadius: DSHRadius.md, style: .continuous)
          .strokeBorder(DSHTheme.onAccent.opacity(hovering ? 0.18 : 0.10), lineWidth: 1)
      }
      .scaleEffect(configuration.isPressed ? 0.99 : 1)
      .opacity(!isEnabled ? 0.42 : configuration.isPressed ? 0.84 : 1)
      .onHover { hovering = isEnabled && $0 }
      .animation(.easeOut(duration: 0.15), value: hovering)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

struct DSHSecondaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(DSHType.label)
      .padding(.horizontal, DSHSpace.s3).padding(.vertical, 8)
      .background(
        hovering ? DSHTheme.surfaceTint2 : DSHTheme.surfaceTint,
        in: RoundedRectangle(cornerRadius: DSHRadius.md, style: .continuous))
      .foregroundStyle(DSHTheme.ink)
      .overlay {
        RoundedRectangle(cornerRadius: DSHRadius.md, style: .continuous)
          .strokeBorder(DSHTheme.fieldStroke.opacity(hovering ? 0.65 : 0.38), lineWidth: 1)
      }
      .scaleEffect(configuration.isPressed ? 0.99 : 1)
      .opacity(!isEnabled ? 0.42 : configuration.isPressed ? 0.75 : 1)
      .onHover { hovering = isEnabled && $0 }
      .animation(.easeOut(duration: 0.15), value: hovering)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

struct DSHGhostButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(DSHType.label)
      .frame(minWidth: 28, minHeight: 28)
      .background(
        hovering ? DSHTheme.surfaceTint2 : Color.clear,
        in: RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous))
      .foregroundStyle(DSHTheme.inkSoft)
      .opacity(!isEnabled ? 0.36 : configuration.isPressed ? 0.6 : 1)
      .onHover { hovering = isEnabled && $0 }
      .animation(.easeOut(duration: 0.15), value: hovering)
  }
}

struct DSHIconButtonStyle: ButtonStyle {
  enum Tone { case primary, secondary }

  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false
  let tone: Tone

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .frame(width: 30, height: 30)
      .background(background, in: RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous))
      .foregroundStyle(tone == .primary ? DSHTheme.onAccent : DSHTheme.inkSoft)
      .overlay {
        RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous)
          .strokeBorder(
            tone == .primary
              ? DSHTheme.onAccent.opacity(hovering ? 0.18 : 0.10)
              : DSHTheme.fieldStroke.opacity(hovering ? 0.65 : 0.38),
            lineWidth: 1)
      }
      .scaleEffect(configuration.isPressed ? 0.96 : 1)
      .opacity(!isEnabled ? 0.38 : configuration.isPressed ? 0.72 : 1)
      .onHover { hovering = isEnabled && $0 }
      .animation(.easeOut(duration: 0.15), value: hovering)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }

  private var background: Color {
    switch tone {
    case .primary:
      return DSHTheme.accentSolid
    case .secondary:
      return hovering ? DSHTheme.surfaceTint2 : DSHTheme.surfaceTint
    }
  }
}

extension ButtonStyle where Self == DSHPrimaryButtonStyle {
  static var dshPrimary: DSHPrimaryButtonStyle { .init() }
}
extension ButtonStyle where Self == DSHSecondaryButtonStyle {
  static var dshSecondary: DSHSecondaryButtonStyle { .init() }
}
extension ButtonStyle where Self == DSHGhostButtonStyle {
  static var dshGhost: DSHGhostButtonStyle { .init() }
}
extension ButtonStyle where Self == DSHIconButtonStyle {
  static var dshIconPrimary: DSHIconButtonStyle { .init(tone: .primary) }
  static var dshIconSecondary: DSHIconButtonStyle { .init(tone: .secondary) }
}
