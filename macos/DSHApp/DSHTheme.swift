import SwiftUI
import AppKit

/// Ocean-toned design tokens — the single source of color/radius/spacing
/// for the whole app. See
/// .agents/notes/proposed/architecture/2026-08-17-ocean-design-system.md.
/// Every view should read colors/radii/spacing from here rather than
/// inlining new literals, so the palette stays consistent across the
/// ~40-file surface it's applied to.
enum DSHTheme {
  /// Builds a `Color` that redraws itself from light/dark sRGB triples as
  /// the system appearance changes — no Asset Catalog needed (this project
  /// deliberately has no Xcode project; see AGENTS.md).
  private static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
    Color(NSColor(name: nil) { appearance in
      let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      let c = isDark ? dark : light
      return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
    })
  }

  // MARK: Text

  static let ink = dynamic(light: (0.1176, 0.2118, 0.2039), dark: (0.8941, 0.9412, 0.9255))
  static let inkSoft = dynamic(light: (0.3725, 0.4902, 0.4745), dark: (0.6157, 0.7294, 0.7098))
  static let inkFaint = dynamic(light: (0.5765, 0.6745, 0.6588), dark: (0.4235, 0.5451, 0.5255))

  // MARK: Surfaces — canvas < surface < surfaceTint < surfaceTint2 forms the
  // depth ladder regions are told apart by; nothing here is a border.

  static let canvas = dynamic(light: (0.9686, 0.9843, 0.9765), dark: (0.0784, 0.1569, 0.1647))
  static let surface = dynamic(light: (1.0, 1.0, 1.0), dark: (0.1059, 0.2039, 0.2118))
  static let surfaceTint = dynamic(light: (0.9373, 0.9647, 0.9529), dark: (0.1216, 0.2314, 0.2353))
  static let surfaceTint2 = dynamic(light: (0.8902, 0.9333, 0.9176), dark: (0.1373, 0.2667, 0.2706))

  /// Sidebar background — one gentle step off `canvas`, not a heavy block.
  static let sidebarBg = dynamic(light: (0.9137, 0.9529, 0.9412), dark: (0.0863, 0.1882, 0.1804))
  static let sidebarSelected = dynamic(light: (0.8627, 0.9333, 0.9098), dark: (0.1176, 0.2392, 0.2275))

  // MARK: Accent — one brand color plus a brighter "live/active" step.
  // Keep the bright step reserved for running/selected state, not decoration.

  static let accent = dynamic(light: (0.1020, 0.5608, 0.5255), dark: (0.3098, 0.7608, 0.7059))
  static let accentBright = dynamic(light: (0.2471, 0.7216, 0.6745), dark: (0.4314, 0.8510, 0.7882))
  /// Foreground drawn on top of an accent-filled surface (buttons, selected chips).
  static let accentContrast = Color(red: 0.043, green: 0.129, blue: 0.122)
  static let accentSoft = dynamic(light: (0.878, 0.949, 0.933), dark: (0.098, 0.243, 0.231))

  // MARK: Semantic — attention / destructive, kept distinct from the accent hue.

  static let warm = dynamic(light: (0.8510, 0.6627, 0.4078), dark: (0.8863, 0.7412, 0.5176))
  static let warmSoft = dynamic(light: (0.965, 0.925, 0.851), dark: (0.204, 0.169, 0.098))
  static let coral = dynamic(light: (0.8314, 0.4706, 0.3725), dark: (0.8863, 0.5725, 0.4667))
  static let coralSoft = dynamic(light: (0.961, 0.878, 0.847), dark: (0.204, 0.129, 0.098))
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

/// Flat field chrome for `TextField`/`SecureField`: a background block
/// instead of the system bezel, matching the app-wide "no strokes" surface
/// language. The single source for text-input styling — every sheet's
/// single-line input should use this rather than reimplementing it locally.
struct DSHFieldBackground: ViewModifier {
  var tint: Color = DSHTheme.surface
  var radius: CGFloat = DSHRadius.sm
  func body(content: Content) -> some View {
    content
      .textFieldStyle(.plain)
      .foregroundStyle(DSHTheme.ink)
      .padding(.horizontal, DSHSpace.s3)
      .padding(.vertical, DSHSpace.s2)
      .background(tint, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
  }
}

extension View {
  /// Background-only card chrome — no stroke, no shadow by default. Callers
  /// still own their own internal layout/padding.
  func dshCard(tint: Color = DSHTheme.surface, radius: CGFloat = DSHRadius.lg) -> some View {
    background(tint, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
  }
  func dshSectionLabel() -> some View { modifier(DSHSectionLabel()) }
  func dshField(tint: Color = DSHTheme.surface, radius: CGFloat = DSHRadius.sm) -> some View {
    modifier(DSHFieldBackground(tint: tint, radius: radius))
  }
}

// MARK: - Button styles

struct DSHPrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .semibold))
      .padding(.horizontal, DSHSpace.s4).padding(.vertical, 10)
      .background(DSHTheme.accentBright, in: RoundedRectangle(cornerRadius: DSHRadius.md, style: .continuous))
      .foregroundStyle(DSHTheme.accentContrast)
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
