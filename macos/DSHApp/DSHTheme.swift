import SwiftUI
import AppKit

/// Fresh light-blue design tokens — the single source of color/radius/spacing
/// for the whole app. See
/// .agents/notes/implemented/architecture/2026-08-17-fresh-light-palette.md.
/// Every view should read colors/radii/spacing from here rather than
/// inlining new literals, so the palette stays consistent across the
/// ~40-file surface it's applied to.
///
/// Light-only by design: the app forces `.aqua` appearance at launch
/// (DSHNativeApp.init), so there is exactly one palette here — airy
/// near-white surfaces with a whisper of cool blue, slate-blue text
/// (deliberately not pure black), and a clear sky-blue accent reserved
/// for the few spots that carry real state (primary action, running
/// indicator, warning/error), not for decoration.
enum DSHTheme {
  // MARK: Text — slate blue, not black.

  static let ink = Color(red: 0.169, green: 0.227, blue: 0.286)
  static let inkSoft = Color(red: 0.361, green: 0.435, blue: 0.502)
  static let inkFaint = Color(red: 0.561, green: 0.631, blue: 0.690)

  // MARK: Surfaces — canvas < surface < surfaceTint < surfaceTint2 forms the
  // depth ladder regions are told apart by; nothing here is a border.

  static let canvas = Color(red: 0.973, green: 0.984, blue: 0.992)
  static let surface = Color(red: 1.0, green: 1.0, blue: 1.0)
  static let surfaceTint = Color(red: 0.945, green: 0.965, blue: 0.980)
  static let surfaceTint2 = Color(red: 0.906, green: 0.941, blue: 0.965)
  /// Editable controls need stronger separation than passive settings rows.
  static let fieldFill = Color(red: 0.992, green: 0.996, blue: 1.0)
  static let fieldStroke = Color(red: 0.655, green: 0.745, blue: 0.816)

  /// Sidebar background — a hair off `canvas`, closer to a recessed neutral
  /// panel than a "colored block".
  static let sidebarBg = Color(red: 0.953, green: 0.973, blue: 0.984)
  static let sidebarSelected = Color(red: 0.886, green: 0.933, blue: 0.965)

  // MARK: Accent — one clear sky-blue family. `accent` is the text/icon
  // step (deep enough to read on the light washes), `accentBright` is
  // reserved for running/selected indicators, `accentWash` is the light
  // fill behind the primary action — filled controls stay light-bodied,
  // only their label carries the color.

  static let accent = Color(red: 0.055, green: 0.435, blue: 0.663)
  static let accentBright = Color(red: 0.153, green: 0.627, blue: 0.871)
  /// Light sky fill for the primary action — pairs with `accent` foreground.
  static let accentWash = Color(red: 0.812, green: 0.914, blue: 0.969)
  static let accentSoft = Color(red: 0.890, green: 0.953, blue: 0.988)

  // MARK: Semantic — attention / destructive, kept distinct from the accent hue.

  static let warm = Color(red: 0.820, green: 0.573, blue: 0.196)
  static let warmSoft = Color(red: 0.996, green: 0.953, blue: 0.878)
  static let coral = Color(red: 0.851, green: 0.416, blue: 0.369)
  static let coralSoft = Color(red: 0.992, green: 0.925, blue: 0.914)
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
