import SwiftUI
import AppKit

/// Jelly-sea design tokens — the single source of color/radius/spacing
/// for the whole app. See
/// .agents/notes/implemented/architecture/2026-08-17-jelly-sea-theme.md.
/// Every view should read colors/radii/spacing from here rather than
/// inlining new literals, so the palette stays consistent across the
/// ~40-file surface it's applied to.
///
/// The look is "果冻海" — translucent, clear, luminous. Both appearances
/// share the same construction: an aqua sea-water canvas at the bottom,
/// and every surface above it is a *translucent* wash (alpha < 1) so
/// layers glow through each other like jelly. Light mode is bright
/// lagoon water; dark mode is deep-sea glass. Hard rule carried over
/// from user feedback: a dark background always pairs with light text —
/// never black-on-dark.
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

  // MARK: Text — deep sea-teal in light mode, pale aqua-white in dark.

  static let ink = dynamic(light: (0.102, 0.239, 0.263, 1), dark: (0.867, 0.949, 0.937, 1))
  static let inkSoft = dynamic(light: (0.318, 0.459, 0.482, 1), dark: (0.627, 0.761, 0.745, 1))
  static let inkFaint = dynamic(light: (0.529, 0.647, 0.663, 1), dark: (0.451, 0.576, 0.561, 1))

  // MARK: Surfaces — an opaque sea canvas at the bottom, then translucent
  // washes stacked on top. canvas < surface < surfaceTint < surfaceTint2
  // is still the depth ladder; depth now reads as "more jelly layers",
  // and stacked layers deepen naturally because of the alpha.

  static let canvas = dynamic(light: (0.918, 0.980, 0.973, 1), dark: (0.043, 0.125, 0.141, 1))
  static let surface = dynamic(light: (1.0, 1.0, 1.0, 0.72), dark: (1.0, 1.0, 1.0, 0.07))
  static let surfaceTint = dynamic(light: (0.804, 0.945, 0.937, 0.55), dark: (0.290, 0.871, 0.824, 0.08))
  static let surfaceTint2 = dynamic(light: (0.729, 0.914, 0.902, 0.65), dark: (0.290, 0.871, 0.824, 0.13))
  /// Editable controls need stronger separation than passive settings rows.
  static let fieldFill = dynamic(light: (1.0, 1.0, 1.0, 0.85), dark: (1.0, 1.0, 1.0, 0.06))
  static let fieldStroke = dynamic(light: (0.573, 0.769, 0.749, 1), dark: (0.290, 0.871, 0.824, 0.35))

  /// Sidebar background — a thinner wash than content cards, so the sea
  /// canvas shows through strongest at the window's edge.
  static let sidebarBg = dynamic(light: (1.0, 1.0, 1.0, 0.40), dark: (1.0, 1.0, 1.0, 0.03))
  static let sidebarSelected = dynamic(light: (0.678, 0.898, 0.882, 0.75), dark: (0.290, 0.871, 0.824, 0.18))

  /// The sea itself — a soft vertical drift behind everything. Views that
  /// paint the window floor should prefer this over flat `canvas`.
  static let canvasGradient = LinearGradient(
    colors: [
      dynamic(light: (0.941, 0.992, 0.984, 1), dark: (0.055, 0.153, 0.169, 1)),
      dynamic(light: (0.851, 0.957, 0.961, 1), dark: (0.031, 0.098, 0.118, 1)),
    ],
    startPoint: .top, endPoint: .bottom)

  // MARK: Accent — clear lagoon turquoise. `accent` is the text/icon step
  // (deep enough to read on the light washes), `accentBright` is reserved
  // for running/selected indicators, `accentWash` is the translucent
  // aqua fill behind the primary action — filled controls stay light-
  // bodied, only their label carries the color.

  static let accent = dynamic(light: (0.039, 0.494, 0.463, 1), dark: (0.427, 0.898, 0.847, 1))
  static let accentBright = dynamic(light: (0.173, 0.773, 0.722, 1), dark: (0.376, 0.925, 0.871, 1))
  /// Translucent aqua fill for the primary action — pairs with `accent` foreground.
  static let accentWash = dynamic(light: (0.565, 0.898, 0.859, 0.60), dark: (0.290, 0.871, 0.824, 0.20))
  static let accentSoft = dynamic(light: (0.702, 0.933, 0.906, 0.45), dark: (0.290, 0.871, 0.824, 0.12))

  // MARK: Semantic — attention / destructive, kept distinct from the accent hue.

  static let warm = dynamic(light: (0.851, 0.604, 0.169, 1), dark: (0.937, 0.757, 0.404, 1))
  static let warmSoft = dynamic(light: (0.980, 0.878, 0.596, 0.45), dark: (0.937, 0.757, 0.404, 0.14))
  static let coral = dynamic(light: (0.886, 0.439, 0.373, 1), dark: (0.945, 0.604, 0.541, 1))
  static let coralSoft = dynamic(light: (0.973, 0.749, 0.702, 0.40), dark: (0.945, 0.604, 0.541, 0.14))
}

/// Four-step corner radius scale — every rounded shape in the app should
/// pick one of these instead of a literal.
enum DSHRadius {
  static let sm: CGFloat = 8
  static let md: CGFloat = 12
  static let lg: CGFloat = 16
  static let xl: CGFloat = 22
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
    case .live: DSHTheme.accentBright
    case .unread: DSHTheme.warm
    case .idle: .clear
    case .success: DSHTheme.accentBright
    case .failure: DSHTheme.coral
    }
  }
}

/// Small capsule label — exit codes, HTTP status, truncation notices, tags.
struct DSHBadge: View {
  enum Tone { case neutral, accent, warm, coral }
  let text: String
  var tone: Tone = .neutral
  var body: some View {
    Text(text)
      .font(.system(size: 10.5, weight: .semibold))
      .padding(.horizontal, DSHSpace.s2).padding(.vertical, 3)
      .background(background, in: Capsule())
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

/// Uppercase, letter-spaced section label ("工作区", "会话", "运行与工具"…).
struct DSHSectionLabel: ViewModifier {
  func body(content: Content) -> some View {
    content.font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(DSHTheme.inkFaint)
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
  func dshCard(tint: Color = DSHTheme.surface, radius: CGFloat = DSHRadius.lg) -> some View {
    background(tint, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
  }
  func dshSectionLabel() -> some View { modifier(DSHSectionLabel()) }
  func dshField(tint: Color = DSHTheme.fieldFill, radius: CGFloat = DSHRadius.sm) -> some View {
    modifier(DSHFieldBackground(tint: tint, radius: radius))
  }
}

// MARK: - Button styles

struct DSHPrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .semibold))
      .padding(.horizontal, DSHSpace.s4).padding(.vertical, 10)
      .background(DSHTheme.accentWash, in: RoundedRectangle(cornerRadius: DSHRadius.md, style: .continuous))
      .foregroundStyle(DSHTheme.accent)
      .opacity(configuration.isPressed ? 0.82 : 1)
  }
}

struct DSHSecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12.5, weight: .medium))
      .padding(.horizontal, DSHSpace.s3).padding(.vertical, 8)
      .background(DSHTheme.surfaceTint2, in: RoundedRectangle(cornerRadius: DSHRadius.md, style: .continuous))
      .foregroundStyle(DSHTheme.ink)
      .opacity(configuration.isPressed ? 0.75 : 1)
  }
}

struct DSHGhostButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(DSHTheme.inkSoft)
      .opacity(configuration.isPressed ? 0.6 : 1)
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
