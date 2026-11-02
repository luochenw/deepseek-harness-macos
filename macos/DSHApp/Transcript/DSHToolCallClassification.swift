import AppKit
import Foundation
import SwiftUI

/// The folded group line: "执行了 N 条命令 · 其中 M 条修改了文件".
struct DSHToolGroupDigest: Equatable {
  let commandCount: Int
  let mutatingCount: Int
  let runningTitle: String?
  /// How many calls in the group ended in an error state. Shown as a coral
  /// 「N 条失败」 chip: without it a folded group of 50 commands looked
  /// identical whether every one succeeded or three blew up.
  var failedCount: Int = 0
  var interruptedCount: Int = 0

  var isRunning: Bool { runningTitle != nil }
  var isFailed: Bool { failedCount > 0 }
  var isInterrupted: Bool { interruptedCount > 0 }

  var failedSummary: String? {
    failedCount > 0 ? "\(failedCount) 条失败" : nil
  }

  var interruptedSummary: String? {
    interruptedCount > 0 ? "\(interruptedCount) 条已中断" : nil
  }

  /// Body of the collapsed line. The mutating sentence is NOT glued on here:
  /// it renders as an accent chip next to this text (see `mutatingSummary`).
  var headline: String { "执行了 \(commandCount) 条命令" }

  var mutatingSummary: String? {
    mutatingCount > 0 ? "其中 \(mutatingCount) 条修改了文件" : nil
  }
}

/// Colours the tool rows are painted with, resolved from `DSHTheme` — never
/// inlined. Text is always the normal body colour; the accent is only used for
/// the pencil glyph, the 2pt leading bar, and the chip outline. That keeps
/// title contrast well above 4.5:1 on every row fill in both appearances
/// (asserted in DSHTests).
enum DSHToolRowPalette {
  static var title: Color { DSHTheme.ink }
  static var secondary: Color { DSHTheme.inkSoft }
  static var rowFill: Color { DSHTheme.surfaceTint }
  static var rowFillHovered: Color { DSHTheme.surfaceTint2 }
  static var canvas: Color { DSHTheme.canvas }
  static var accent: Color { DSHTheme.accent }
  static var chipText: Color { DSHTheme.ink }

  /// The `accentSoft` chip fill is the accent at 11% over the row fill, so
  /// contrast must be measured against that blend, not against the accent.
  static var chipFill: Color { DSHTheme.accentSoft }
}

/// WCAG 2.x relative luminance / contrast, computed from the theme's real
/// sRGB components so a regression in the palette fails a test instead of
/// quietly making transcript text unreadable.
enum DSHContrast {
  struct RGB: Equatable {
    let r: Double
    let g: Double
    let b: Double
  }

  static func ratio(_ foreground: RGB, _ background: RGB) -> Double {
    let a = luminance(foreground)
    let b = luminance(background)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }

  static func luminance(_ color: RGB) -> Double {
    0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b)
  }

  private static func linear(_ component: Double) -> Double {
    component <= 0.04045
      ? component / 12.92
      : pow((component + 0.055) / 1.055, 2.4)
  }

  /// Composite `top` (with `alpha`) over `bottom`.
  static func blend(_ top: RGB, alpha: Double, over bottom: RGB) -> RGB {
    RGB(
      r: top.r * alpha + bottom.r * (1 - alpha),
      g: top.g * alpha + bottom.g * (1 - alpha),
      b: top.b * alpha + bottom.b * (1 - alpha))
  }

  /// Resolve a `DSHTheme` colour in one appearance. Dynamic colours only
  /// expose their light/dark pair through AppKit, so the appearance has to be
  /// current while the `NSColor` is converted.
  static func rgba(_ color: Color, appearance: NSAppearance.Name) -> RGB? {
    guard let appearance = NSAppearance(named: appearance) else { return nil }
    var resolved: NSColor?
    appearance.performAsCurrentDrawingAppearance {
      resolved = NSColor(color).usingColorSpace(.sRGB)
    }
    guard let resolved else { return nil }
    return RGB(
      r: Double(resolved.redComponent),
      g: Double(resolved.greenComponent),
      b: Double(resolved.blueComponent))
  }
}

enum DSHToolGroupDigestBuilder {
  struct Call: Equatable {
    let title: String
    let kind: DSHToolCallKind
    let running: Bool
    var failed: Bool = false
    var interrupted: Bool = false
  }

  static func digest(for calls: [Call]) -> DSHToolGroupDigest? {
    guard !calls.isEmpty else { return nil }
    // The running label names the command actually being executed: the LAST
    // call that is still running, not the last call in the list (finished
    // calls may follow a live one when the Host settles them out of order).
    let running = calls.last(where: { $0.running })?.title
    return DSHToolGroupDigest(
      commandCount: calls.count,
      mutatingCount: calls.filter { $0.kind.isMutating }.count,
      runningTitle: running,
      failedCount: calls.filter(\.failed).count,
      interruptedCount: calls.filter(\.interrupted).count)
  }
}

/// Convenience views over one activity for the transcript rows.
extension HarnessController.ToolActivity {
  /// Parsed `cd …` prefix (and the summarized title) for shell activities.
  var commandSummary: DSHCommandSummary? {
    guard DSHToolCallShape.isShellTool(name),
          let command = DSHToolGroupStatus.shellCommand(for: self) else {
      return nil
    }
    return DSHCommandTitle.summarize(command)
  }

  var callKind: DSHToolCallKind {
    DSHToolCallClassifier.kind(for: self)
  }
}
