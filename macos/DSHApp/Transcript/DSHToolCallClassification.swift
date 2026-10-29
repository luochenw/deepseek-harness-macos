import AppKit
import Foundation
import SwiftUI

/// Precompiled regular expressions for the command summarizer and the write
/// classifier.
///
/// Every pattern below used to be a string literal passed to
/// `String.range(of:options:.regularExpression)`, which compiles the pattern on
/// every call. One body evaluation of a 64-command group compiled ~1 400
/// regexes, which is what froze the app on 2026-10-29 (see
/// `.agents/notes/proposed/bug-fix/2026-10-29-tool-group-expand-freeze.md`).
/// The pattern TEXT is unchanged — only the compilation moved to `static let`
/// initialization — so classification semantics are identical; the before/after
/// classification dump over every fixture command proves it.
enum DSHPrecompiledPattern {
  /// `nil` when the pattern does not compile. A bad literal is a programming
  /// error the pattern-compilation test catches at build time; at runtime the
  /// caller must then treat the rule as NOT matching. The old fallback
  /// (`NSRegularExpression()`) was an empty pattern, which matches everything —
  /// every command would have been classified as writing files.
  static func expression(
    _ pattern: String,
    caseInsensitive: Bool = false
  ) -> NSRegularExpression? {
    do {
      return try NSRegularExpression(
        pattern: pattern,
        options: caseInsensitive ? [.caseInsensitive] : [])
    } catch {
      assertionFailure("invalid classification pattern: \(pattern)")
      return nil
    }
  }

  /// How many patterns are declared; the pattern-compilation test walks them so
  /// a broken literal cannot ship as "silently never matches".
  static var declaredPatternCount: Int {
    DSHCommandTitle.declaredPatterns.count
      + DSHToolCallClassifier.declaredPatterns.count
      + 2  // pythonInterpreter, nodeInterpreter
  }

  static var declaredPatternsAreAllCompiled: Bool {
    let title = DSHCommandTitle.declaredPatterns.allSatisfy { $0 != nil }
    let classifier = DSHToolCallClassifier.declaredPatterns.allSatisfy { $0 != nil }
    return title && classifier && pythonInterpreter != nil && nodeInterpreter != nil
  }

  /// `python3` / `python3.12` … and a `node` invocation at the start of a line.
  /// Shared by the title summarizer and the write classifier so the two can
  /// never drift apart.
  static let pythonInterpreter = expression(#"python[0-9.]*(\s|$)"#)
  static let nodeInterpreter = expression(#"^node(\s|$)"#)

  static func firstMatch(_ expression: NSRegularExpression?, in text: String) -> NSRange? {
    // A pattern that failed to compile never matches — see `expression(_:)`.
    guard let expression else { return nil }
    return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.range
  }

  static func matches(_ expression: NSRegularExpression?, _ text: String) -> Bool {
    firstMatch(expression, in: text) != nil
  }

  static func range(
    of expression: NSRegularExpression?,
    in text: String
  ) -> Range<String.Index>? {
    guard let match = firstMatch(expression, in: text) else { return nil }
    return Range(match, in: text)
  }
}

/// Whether a tool call changes files on disk, so a run of commands does not read
/// as an undifferentiated ladder of terminal rows.
///
/// A pure function of the tool name plus its raw argument string: no App state,
/// no Host round trip, so it is testable against real Host payloads.
enum DSHToolCallKind: Equatable {
  case readOnly
  case mutating

  var isMutating: Bool { self == .mutating }
}

/// Tools whose transcript rows can be folded into one "commands" group. Agent
/// and subagent dispatches are deliberately absent: merging them would hide a
/// delegation behind a command count.
enum DSHToolCallShape {
  /// Shell tools share the command summarizer; keep the list in one place.
  static let shellTools: Set<String> = ["bash", "shell", "sh", "zsh"]

  static let commandTools: Set<String> = shellTools.union([
    "read", "write", "edit", "multi_edit", "apply_patch",
    "glob", "grep", "read_image",
    "job_output", "job_kill", "job_list", "job_wait",
  ])

  /// Tools that change files on disk.
  static let mutatingTools: Set<String> = [
    "write", "edit", "multi_edit", "apply_patch", "notebook_edit",
  ]

  static func isCommandTool(_ name: String) -> Bool {
    commandTools.contains(name.lowercased())
  }

  static func isShellTool(_ name: String) -> Bool {
    shellTools.contains(name.lowercased())
  }

  /// Last-resort label for a command tool whose own arguments carried no
  /// usable subject. Command rows may never render as a bare icon.
  static func fallbackTitle(for name: String) -> String? {
    if let job = DSHJobToolCopy.title(for: name) { return job }
    return switch name.lowercased() {
    case "bash", "shell", "sh", "zsh": "运行命令"
    case "read": "读取文件"
    case "write": "写入文件"
    case "edit", "multi_edit": "修改文件"
    case "apply_patch": "应用补丁"
    case "glob", "grep": "搜索文件"
    case "read_image": "查看图片"
    default: nil
    }
  }
}

/// Friendly copy for the background-job tools, the single table for both the
/// shaped rows and their fallback titles: `job_output`/`job_kill` carry no file
/// path, so their raw argument text used to become the row title.
enum DSHJobToolCopy {
  static func title(for name: String) -> String? {
    switch name.lowercased() {
    case "job_output", "job_wait": "等待后台任务输出"
    case "job_kill": "停止后台任务"
    case "job_list": "查看后台任务"
    default: nil
    }
  }
}

/// The folded group line: "执行了 N 条命令 · 其中 M 条修改了文件".
struct DSHToolGroupDigest: Equatable {
  let commandCount: Int
  let mutatingCount: Int
  let runningTitle: String?
  /// How many calls in the group ended in an error state. Shown as a coral
  /// 「N 条失败」 chip: without it a folded group of 50 commands looked
  /// identical whether every one succeeded or three blew up.
  var failedCount: Int = 0

  var isRunning: Bool { runningTitle != nil }
  var isFailed: Bool { failedCount > 0 }

  var failedSummary: String? {
    failedCount > 0 ? "\(failedCount) 条失败" : nil
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
      failedCount: calls.filter(\.failed).count)
  }
}

/// A readable subject for one shell command. Titles are never empty: the
/// summarizer always has a last-resort label, so a transcript row can no
/// longer collapse into an icon with no text.
struct DSHCommandSummary: Equatable {
  let title: String
  let directory: String?
}

enum DSHCommandTitle {
  static func summarize(_ command: String) -> DSHCommandSummary {
    let lines = command.split(whereSeparator: \.isNewline).map(String.init)
    var directory: String?
    var statements: [String] = []
    // Only the first command line matters: a heredoc body is script content,
    // not more shell statements.
    for line in lines {
      for piece in splitStatement(line) {
        let trimmed = unwrapScaffolding(piece.trimmingCharacters(in: .whitespaces))
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        if isDirectoryChange(trimmed) {
          if directory == nil { directory = cdTarget(trimmed) }
          continue
        }
        statements.append(trimmed)
      }
      if !statements.isEmpty { break }
    }

    guard let first = statements.first(where: { !isNoiseStatement($0) && !isAssignmentOnly($0) })
      ?? statements.first(where: { !isNoiseStatement($0) })
      ?? statements.first else {
      return DSHCommandSummary(
        title: directory.map { "进入 \($0)" } ?? "运行命令",
        directory: directory)
    }
    return DSHCommandSummary(
      title: title(for: first, fullCommand: command),
      directory: directory)
  }

  private static func title(for statement: String, fullCommand: String) -> String {
    if let target = pythonWriteTarget(in: fullCommand) {
      return "Python 脚本 · 修改 \(target)"
    }
    if let target = shellWriteTarget(statement) {
      return "写入 \(target)"
    }
    if pythonInvocation(in: statement) != nil,
       let code = firstCodeLine(in: fullCommand) ?? inlinePythonCode(statement) {
      return "Python 脚本 · \(code)"
    }
    if let target = nodeWriteTarget(in: fullCommand) {
      return "Node 脚本 · 修改 \(target)"
    }
    return clamp(statement)
  }

  /// Every pattern this type declares, for the "all patterns compile" test.
  static let declaredPatterns: [NSRegularExpression?] = [
    directoryChangePattern, scaffoldingPattern, noiseHeaderPattern, noiseBareEchoPattern,
    assignmentOnlyPattern, controlKeywordPattern, shellWriteTargetPatterns[0],
    shellWriteTargetPatterns[1], shellWriteTargetPatterns[2], inlinePythonCodePattern,
    assignmentInScriptPattern, openVariableWithWriteModePattern,
    openLiteralWithWriteModePattern, writeTextPattern, openVariableWriteModeWPattern,
    nodeWriteTargetPatterns[0], nodeWriteTargetPatterns[1], nodeWriteTargetPatterns[2],
    heredocMarkerPattern,
  ]

  private static let directoryChangePattern =
    DSHPrecompiledPattern.expression(#"^cd(\s|$)"#)

  private static func isDirectoryChange(_ statement: String) -> Bool {
    DSHPrecompiledPattern.matches(directoryChangePattern, statement)
  }

  /// Strip a leading `do`/`then`/`else` so a loop body line names what it
  /// actually runs: `do mkdir -p "pbr_$n"` → `mkdir -p "pbr_$n"`. The `for` /
  /// `while` header itself is scaffolding and is filtered out instead.
  private static let scaffoldingPattern =
    DSHPrecompiledPattern.expression(#"^(do|then|else)\b\s*"#)

  private static func unwrapScaffolding(_ statement: String) -> String {
    guard let range = DSHPrecompiledPattern.range(of: scaffoldingPattern, in: statement) else {
      return statement
    }
    let rest = statement[range.upperBound...].trimmingCharacters(in: .whitespaces)
    return rest.isEmpty ? statement : rest
  }

  /// `echo "--- label"` between real commands is a section header, not a
  /// subject: prefer the command it introduces.
  private static let noiseHeaderPattern =
    DSHPrecompiledPattern.expression(#"^(echo|printf)\s+['"]?-{1,}\s"#)
  private static let noiseBareEchoPattern =
    DSHPrecompiledPattern.expression(#"^(echo|printf)\s*$"#)

  private static func isNoiseStatement(_ statement: String) -> Bool {
    DSHPrecompiledPattern.matches(noiseHeaderPattern, statement)
      || DSHPrecompiledPattern.matches(noiseBareEchoPattern, statement)
  }

  /// `V=0.169.0` / `for f in …` / `done`: shell scaffolding, not the command
  /// that does the work.
  private static let assignmentOnlyPattern =
    DSHPrecompiledPattern.expression(#"^[A-Za-z_][A-Za-z0-9_]*=\S*$"#)
  private static let controlKeywordPattern =
    DSHPrecompiledPattern.expression(#"^(for|while|until|if|then|elif|else|do|done|fi|esac|\{|\})\b"#)

  private static func isAssignmentOnly(_ statement: String) -> Bool {
    DSHPrecompiledPattern.matches(assignmentOnlyPattern, statement)
      || DSHPrecompiledPattern.matches(controlKeywordPattern, statement)
  }

  private static func splitStatement(_ line: String) -> [String] {
    var pieces: [String] = []
    var current = ""
    var quote: Character?
    let characters = Array(line)
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if let active = quote {
        current.append(character)
        if character == active { quote = nil }
        index += 1
        continue
      }
      if character == "'" || character == "\"" {
        quote = character
        current.append(character)
        index += 1
        continue
      }
      if character == ";" || character == "|" {
        pieces.append(current)
        current = ""
        // `||` and `|` both end the statement; `&&` needs both halves cut.
        if character == "|", index + 1 < characters.count, characters[index + 1] == "|" {
          index += 2
        } else {
          index += 1
        }
        continue
      }
      if character == "&", index + 1 < characters.count, characters[index + 1] == "&" {
        pieces.append(current)
        current = ""
        index += 2
        continue
      }
      current.append(character)
      index += 1
    }
    pieces.append(current)
    return pieces
  }

  private static func cdTarget(_ statement: String) -> String? {
    let rest = statement.dropFirst(2).trimmingCharacters(in: .whitespaces)
    let target = rest.split(separator: " ").first.map(String.init) ?? rest
    let cleaned = target.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    return cleaned.isEmpty ? nil : cleaned
  }

  /// `cat > /tmp/probe.js <<'EOF'` and `cat <<'EOF' > file` read as "写入 …";
  /// a plain heredoc into a command (no redirect) falls through.
  private static let shellWriteTargetPatterns = [
    DSHPrecompiledPattern.expression(#"cat\s*>\s*([^\s<>]+)\s*<<-?"#),
    DSHPrecompiledPattern.expression(#"cat\s*<<-?\s*['"]?[A-Za-z_][A-Za-z0-9_]*['"]?\s*>\s*([^\s<>]+)"#),
    DSHPrecompiledPattern.expression(#"tee\s+(?:-a\s+)?([^\s<>|]+)"#),
  ]

  private static func shellWriteTarget(_ statement: String) -> String? {
    for pattern in shellWriteTargetPatterns {
      if let target = capture(pattern, in: statement) {
        return target.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
      }
    }
    return nil
  }

  /// The python command inside a statement, if any: `python3 - <<'PY'`,
  /// `python3 - <<'PY'` after `&&`, or a `python3 -c '…'` one-liner.
  private static func pythonInvocation(in statement: String) -> Substring? {
    guard let match = DSHPrecompiledPattern.range(
      of: DSHPrecompiledPattern.pythonInterpreter, in: statement) else {
      return nil
    }
    return statement[match.lowerBound...]
  }

  private static let inlinePythonCodePattern =
    DSHPrecompiledPattern.expression(#"python[0-9.]*\s+-c\s+(['"])(.*?)['"]"#)

  /// `python3 -c "…"`: the code itself is the only readable subject.
  private static func inlinePythonCode(_ statement: String) -> String? {
    guard let raw = capture(inlinePythonCodePattern, in: statement) else {
      return nil
    }
    return clamp(raw)
  }

  private static func firstCodeLine(in command: String) -> String? {
    let lines = command.split(whereSeparator: \.isNewline).map(String.init)
    guard let start = lines.firstIndex(where: { pythonInvocation(in: $0) != nil }),
          let marker = heredocMarker(in: lines[start]) else {
      return nil
    }
    for line in lines.dropFirst(start + 1) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed == marker { break }
      if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
      // `import json` says nothing about what the script does.
      if trimmed.hasPrefix("import ") || trimmed.hasPrefix("from ") { continue }
      return clamp(trimmed)
    }
    return nil
  }

  /// `open(p,'w')` write-mode suffix, shared by the two `open(…)` patterns
  /// exactly as it was concatenated before.
  private static let writeModes = #"['"][waxr]?[wax][+]?b?['"]"#

  private static let assignmentInScriptPattern = DSHPrecompiledPattern.expression(
    #"(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*['"]([^'"]+)['"]"#)
  private static let openVariableWithWriteModePattern = DSHPrecompiledPattern.expression(
    #"open\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,\s*"# + writeModes)
  private static let openLiteralWithWriteModePattern = DSHPrecompiledPattern.expression(
    #"open\s*\(\s*['"]([^'"]+)['"]\s*,\s*"# + writeModes)
  private static let writeTextPattern = DSHPrecompiledPattern.expression(
    #"([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*(write_text|write_bytes)\s*\("#)
  private static let openVariableWriteModeWPattern = DSHPrecompiledPattern.expression(
    #"open\s*\(\s*[A-Za-z_][A-Za-z0-9_]*\s*,\s*['"]w"#)

  private static func pythonWriteTarget(in command: String) -> String? {
    guard let script = heredocBody(in: command, interpreter: .python) else { return nil }
    var variables: [String: String] = [:]
    for match in captures(assignmentInScriptPattern, in: script) {
      variables[match[0]] = match[1]
    }
    // `open(p,'w')` / `open('x/y','w')` / `p.write_text(…)`. A read-only
    // `open(p)` is skipped: only a write mode makes it a modification.
    for match in captures(openVariableWithWriteModePattern, in: script) {
      if let path = variables[match[0]] { return path }
    }
    if let literal = capture(openLiteralWithWriteModePattern, in: script) {
      return literal
    }
    for match in captures(writeTextPattern, in: script) {
      if let path = variables[match[0]] { return path }
    }
    // `p = '…'` where p is later mutated in place (`.replace(` on its read
    // content, `open(p,'w')`): the assignment itself names the target.
    if variables.isEmpty == false,
       captures(openVariableWriteModeWPattern, in: script).isEmpty == false,
       let first = variables.sorted(by: { $0.key < $1.key }).first {
      return first.value
    }
    return nil
  }

  private enum Interpreter { case python, node }

  private static let nodeWriteTargetPatterns = [
    DSHPrecompiledPattern.expression(#"fs\.writeFileSync\s*\(\s*['"]([^'"]+)['"]"#),
    DSHPrecompiledPattern.expression(#"fs\.writeFile\s*\(\s*['"]([^'"]+)['"]"#),
    DSHPrecompiledPattern.expression(#"fs\.appendFileSync\s*\(\s*['"]([^'"]+)['"]"#),
  ]

  private static func nodeWriteTarget(in command: String) -> String? {
    guard let script = heredocBody(in: command, interpreter: .node) else { return nil }
    for pattern in nodeWriteTargetPatterns {
      if let target = capture(pattern, in: script) { return target }
    }
    return nil
  }

  private static func heredocBody(in command: String, interpreter: Interpreter) -> String? {
    let lines = command.split(whereSeparator: \.isNewline).map(String.init)
    guard let start = lines.firstIndex(where: { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.contains("<<") else { return false }
      switch interpreter {
      case .python: return pythonInvocation(in: trimmed) != nil
      case .node: return DSHPrecompiledPattern.matches(DSHPrecompiledPattern.nodeInterpreter, trimmed)
      }
    }) else { return nil }
    var body: [String] = []
    for line in lines.dropFirst(start + 1) {
      if line.trimmingCharacters(in: .whitespaces) == heredocMarker(in: lines[start]) { break }
      body.append(line)
    }
    return body.isEmpty ? nil : body.joined(separator: "\n")
  }

  private static let heredocMarkerPattern =
    DSHPrecompiledPattern.expression(#"<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?"#)

  private static func heredocMarker(in line: String) -> String? {
    guard let raw = capture(heredocMarkerPattern, in: line) else {
      return nil
    }
    return raw
  }

  private static func capture(_ expression: NSRegularExpression?, in text: String) -> String? {
    captures(expression, in: text).first?.first
  }

  private static func captures(_ expression: NSRegularExpression?, in text: String) -> [[String]] {
    // A pattern that failed to compile captures nothing (see `expression(_:)`).
    guard let expression else { return [] }
    let full = NSRange(text.startIndex..., in: text)
    return expression.matches(in: text, range: full).map { match in
      (1..<match.numberOfRanges).map { index in
        Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
      }
    }
  }

  private static func clamp(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "运行命令" }
    return trimmed.count > 180 ? String(trimmed.prefix(180)) : trimmed
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

/// Counts classifications that actually ran. The transcript's own counter
/// (`DSHTranscriptPerf.toolGroupClassifications`) trusts the number of calls it
/// handed to the builder; this one is incremented inside the classifier, so a
/// test that renders the real row can prove the ROW did not re-classify — a
/// stale `digest` getter shows up here, not there.
enum DSHClassificationCounter {
  #if DEBUG
  static var classifiedCalls = 0
  @inline(__always) static func noteClassifiedCall() {
    guard DSHTranscriptPerf.isEnabled else { return }
    classifiedCalls += 1
  }
  #else
  @inline(__always) static func noteClassifiedCall() {}
  #endif
}

enum DSHToolCallClassifier {
  /// Classification for a live activity: falls back to the Host-projected
  /// title as the command text when the App did not retain the raw arguments
  /// (history entries built from a projection keep only `presentation.title`).
  static func kind(for activity: HarnessController.ToolActivity) -> DSHToolCallKind {
    DSHClassificationCounter.noteClassifiedCall()
    if DSHToolCallShape.mutatingTools.contains(activity.name.lowercased()) {
      return .mutating
    }
    guard DSHToolCallShape.isShellTool(activity.name) else { return .readOnly }
    // The Host projects the full `command` into `presentation.title`; the live
    // path also keeps the raw JSON arguments. Either is enough.
    let command = DSHToolGroupStatus.shellCommand(for: activity) ?? ""
    return commandWritesFiles(command) ? .mutating : .readOnly
  }

  static func kind(name: String, arguments: String?) -> DSHToolCallKind {
    kind(name: name, arguments: argumentObject(arguments), rawArguments: arguments)
  }

  static func kind(name: String, arguments object: [String: Any]?) -> DSHToolCallKind {
    kind(name: name, arguments: object, rawArguments: nil)
  }

  static func kind(
    name: String,
    arguments object: [String: Any]?,
    rawArguments: String?
  ) -> DSHToolCallKind {
    if DSHToolCallShape.mutatingTools.contains(name.lowercased()) {
      return .mutating
    }
    guard DSHToolCallShape.isShellTool(name) else { return .readOnly }
    let command = (object?["command"] as? String) ?? rawArguments ?? ""
    return commandWritesFiles(command) ? .mutating : .readOnly
  }

  /// True when a shell command matches one of the write patterns the
  /// transcript treats as "modified code". `2>&1`-style redirections and
  /// `>/dev/null` do not count: they are plumbing, not file edits.
  static func commandWritesFiles(_ command: String) -> Bool {
    let text = command.isEmpty ? "" : command
    guard !text.isEmpty else { return false }
    let tokens = shellStatements(text)
    for statement in tokens {
      if statementWritesFiles(statement) { return true }
    }
    if let script = pythonScript(in: text), pythonWritesFiles(script) { return true }
    if let script = nodeScript(in: text), nodeWritesFiles(script) { return true }
    return false
  }

  private static func statementWritesFiles(_ statement: String) -> Bool {
    if containsBareRedirect(statement) { return true }
    if downloadWritesToDevNull(statement) { return false }
    return simpleWritePatterns.contains {
      matches(statement, $0)
    }
  }

  private static let simpleWritePatterns: [NSRegularExpression?] = [
    #"(^|\s)tee(\s|$)"#,
    #"(^|\s)sed\s+(-[a-zA-Z]*\s+)*-[a-zA-Z]*i"#,
    #"(^|\s)mv(\s|$)"#,
    #"(^|\s)rm(\s|$)"#,
    #"(^|\s)cp(\s|$)"#,
    #"(^|\s)mkdir(\s|$)"#,
    #"(^|\s)touch(\s|$)"#,
    #"(^|\s)chmod(\s|$)"#,
    #"(^|\s)chown(\s|$)"#,
    #"(^|\s)ln(\s|$)"#,
    #"(^|\s)truncate(\s|$)"#,
    #"(^|\s)install(\s|$)"#,
    #"(^|\s)git\s+(apply|checkout|reset|commit|rm|mv|clean|stash|switch|merge|rebase)(\s|$)"#,
    #"(^|\s)(npm|pnpm|yarn)\s+(i|install|add|remove|uninstall)(\s|$)"#,
    #"(^|\s)curl[^|;]*\s(-o|--output|-O|--remote-name)(\s|$)"#,
    #"(^|\s)wget(\s|$)"#,
    #"(^|\s)tar\s+[^|;]*-[a-zA-Z]*[xc]"#,
    #"(^|\s)unzip(\s|$)"#,
    #"(^|\s)zip(\s|$)"#,
    #"(^|\s)ditto(\s|$)"#,
    #"(^|\s)rsync(\s|$)"#,
    #"(^|\s)perl\s+[^|;]*-[a-zA-Z]*i"#,
  ].map { DSHPrecompiledPattern.expression($0, caseInsensitive: true) }

  /// `curl -s -o /dev/null URL` / `wget -O /dev/null`: a discard, not a write.
  private static let downloadURLPattern =
    DSHPrecompiledPattern.expression(#"(curl|wget)\b"#)
  private static let downloadDevNullPattern =
    DSHPrecompiledPattern.expression(#"(-o|--output|-O|--remote-name)\s*['"]?/dev/null"#)

  private static func downloadWritesToDevNull(_ statement: String) -> Bool {
    guard DSHPrecompiledPattern.matches(downloadURLPattern, statement) else { return false }
    return DSHPrecompiledPattern.matches(downloadDevNullPattern, statement)
  }

  /// `>` or `>>` that is a real redirect: not `2>&1`, not `>/dev/null`,
  /// not part of a heredoc marker (`<<'EOF'`) or a comparison.
  private static func containsBareRedirect(_ statement: String) -> Bool {
    var index = statement.startIndex
    while index < statement.endIndex {
      let character = statement[index]
      guard character == ">" else {
        index = statement.index(after: index)
        continue
      }
      var next = statement.index(after: index)
      var target = next
      if next < statement.endIndex, statement[next] == ">" {
        next = statement.index(after: next)
        target = next
      }
      if target < statement.endIndex, statement[target] == "&" {
        index = target
        continue
      }
      let rest = statement[target...].trimmingCharacters(in: .whitespaces)
      if rest.hasPrefix("/dev/null") { return false }
      return true
    }
    return false
  }

  private static let pythonWritePatterns: [NSRegularExpression?] = [
    #"open\s*\([^)]*,\s*['"](w|a|x|wb|ab|w\+|a\+|r\+)['"]"#,
    #"\.write_text\s*\("#,
    #"\.write_bytes\s*\("#,
    #"(shutil\.(copy|copy2|copyfile|move|rmtree))"#,
    #"(os\.(remove|unlink|rename|replace|makedirs|mkdir|rmdir))"#,
    #"(json\.dump\s*\()"#,
  ].map { DSHPrecompiledPattern.expression($0, caseInsensitive: true) }

  private static let nodeWritePatterns: [NSRegularExpression?] = [
    #"fs\.(writeFileSync|writeFile|appendFileSync|appendFile|mkdirSync|mkdir|rmSync|rm|unlinkSync|unlink|renameSync|rename)\s*\("#,
    #"(createWriteStream|writeFileSync)"#,
  ].map { DSHPrecompiledPattern.expression($0, caseInsensitive: true) }

  private static func pythonWritesFiles(_ script: String) -> Bool {
    pythonWritePatterns.contains { matches(script, $0) }
  }

  private static func nodeWritesFiles(_ script: String) -> Bool {
    nodeWritePatterns.contains { matches(script, $0) }
  }

  /// Every pattern this type declares, for the "all patterns compile" test.
  static let declaredPatterns: [NSRegularExpression?] =
    simpleWritePatterns + pythonWritePatterns + nodeWritePatterns + [
      downloadURLPattern, downloadDevNullPattern,
    ]

  private static func matches(_ text: String, _ expression: NSRegularExpression?) -> Bool {
    DSHPrecompiledPattern.matches(expression, text)
  }

  private static func shellStatements(_ text: String) -> [String] {
    var statements: [String] = []
    for line in text.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
      for piece in trimmed.split(whereSeparator: { $0 == ";" || $0 == "|" }) {
        let statement = piece.trimmingCharacters(in: .whitespaces)
        if !statement.isEmpty { statements.append(statement) }
      }
    }
    return statements
  }

  private static func pythonScript(in command: String) -> String? {
    scriptBody(in: command) {
      DSHPrecompiledPattern.matches(DSHPrecompiledPattern.pythonInterpreter, $0)
    }
  }

  private static func nodeScript(in command: String) -> String? {
    scriptBody(in: command) {
      DSHPrecompiledPattern.matches(DSHPrecompiledPattern.nodeInterpreter, $0)
    }
  }

  /// Heredoc body for the first line that both invokes `interpreter` and opens
  /// a heredoc. Matching the whole line — not just its start — matters: the
  /// real commands are `cd … && python3 - <<'PY'`.
  private static func scriptBody(
    in command: String,
    matchesInterpreter: (String) -> Bool
  ) -> String? {
    let lines = command.split(whereSeparator: \.isNewline).map(String.init)
    guard let start = lines.firstIndex(where: { line in
      line.contains("<<") && matchesInterpreter(line.trimmingCharacters(in: .whitespaces))
    }), let marker = heredocMarker(in: lines[start]) else { return nil }
    var body: [String] = []
    for line in lines.dropFirst(start + 1) {
      if line.trimmingCharacters(in: .whitespaces) == marker { break }
      body.append(line)
    }
    return body.isEmpty ? nil : body.joined(separator: "\n")
  }

  private static let heredocMarkerPattern =
    DSHPrecompiledPattern.expression(#"<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?"#)

  private static func heredocMarker(in line: String) -> String? {
    guard let range = DSHPrecompiledPattern.range(of: heredocMarkerPattern, in: line) else {
      return nil
    }
    let marker = String(line[range])
      .replacingOccurrences(of: "<<", with: "")
      .replacingOccurrences(of: "-", with: "")
      .trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
    return marker.isEmpty ? nil : marker
  }

  private static func argumentObject(_ value: String?) -> [String: Any]? {
    guard let value, let data = value.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }
}
