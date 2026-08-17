import SwiftUI
import AppKit

/// Ocean-toned design tokens — the single source of color/radius/spacing
/// for the whole app. See
/// .agents/notes/implemented/architecture/2026-08-17-ocean-design-system.md.
/// Every view should read colors/radii/spacing from here rather than
/// inlining new literals, so the palette stays consistent across the
/// ~40-file surface it's applied to.
///
/// Deliberately low-chroma: the first two passes at this palette read as
/// "too heavy" (user feedback, twice) — regions are told apart by a whisper
/// of hue and lightness, not a visibly "colored" block, and saturated color
/// is reserved for the few spots that carry real state (primary action,
/// running indicator, warning/error), not for decoration.
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

  static let ink = dynamic(light: (0.149, 0.188, 0.180), dark: (0.886, 0.914, 0.906))
  static let inkSoft = dynamic(light: (0.384, 0.431, 0.420), dark: (0.576, 0.631, 0.616))
  static let inkFaint = dynamic(light: (0.561, 0.608, 0.596), dark: (0.404, 0.455, 0.435))

  // MARK: Surfaces — canvas < surface < surfaceTint < surfaceTint2 forms the
  // depth ladder regions are told apart by; nothing here is a border.

  static let canvas = dynamic(light: (0.980, 0.984, 0.980), dark: (0.090, 0.125, 0.122))
  static let surface = dynamic(light: (1.0, 1.0, 1.0), dark: (0.118, 0.161, 0.157))
  static let surfaceTint = dynamic(light: (0.953, 0.961, 0.957), dark: (0.129, 0.173, 0.169))
  static let surfaceTint2 = dynamic(light: (0.922, 0.933, 0.929), dark: (0.149, 0.192, 0.184))

  /// Sidebar background — a hair off `canvas`, closer to a recessed neutral
  /// panel than a "colored block".
  static let sidebarBg = dynamic(light: (0.945, 0.957, 0.953), dark: (0.098, 0.133, 0.129))
  static let sidebarSelected = dynamic(light: (0.894, 0.914, 0.906), dark: (0.129, 0.169, 0.161))

  // MARK: Accent — one brand color plus a brighter "live/active" step.
  // Keep the bright step reserved for running/selected state, not decoration.

  static let accent = dynamic(light: (0.361, 0.545, 0.522), dark: (0.435, 0.690, 0.651))
  static let accentBright = dynamic(light: (0.247, 0.612, 0.565), dark: (0.373, 0.745, 0.690))
  /// Foreground drawn on top of an accent-filled surface (buttons, selected chips).
  static let accentContrast = Color(red: 0.043, green: 0.129, blue: 0.122)
  static let accentSoft = dynamic(light: (0.906, 0.937, 0.929), dark: (0.133, 0.200, 0.188))

  // MARK: Semantic — attention / destructive, kept distinct from the accent hue.

  static let warm = dynamic(light: (0.749, 0.631, 0.475), dark: (0.796, 0.690, 0.533))
  static let warmSoft = dynamic(light: (0.945, 0.918, 0.878), dark: (0.180, 0.153, 0.110))
  static let coral = dynamic(light: (0.737, 0.506, 0.443), dark: (0.784, 0.573, 0.514))
  static let coralSoft = dynamic(light: (0.949, 0.894, 0.875), dark: (0.180, 0.129, 0.106))
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
