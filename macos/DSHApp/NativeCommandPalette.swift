import SwiftUI

// MARK: - Slash palette entries

/// One row in the composer's slash palette. Three origins, mirroring the web
/// client's `/` trigger roster: host registry commands (dispatched through
/// `commands/execute`), user-invocable skills (the pick lands the literal
/// `/name ` text and the Host's pre-step gesture boundary injects the skill
/// content), and native local commands whose web implementations live in
/// browser plugins and need a native equivalent (`/model`).
struct DSHSlashEntry: Identifiable {
  enum Kind {
    case command(hint: String?)
    case skill(userOnly: Bool)
    case local(hint: String?)
  }
  let name: String  // without the leading slash
  let description: String
  let kind: Kind
  var id: String { name }

  var hint: String? {
    switch kind {
    case .command(let hint), .local(let hint): hint
    case .skill: nil
    }
  }
  var isSkill: Bool { if case .skill = kind { return true }; return false }
}

// MARK: - Matching

enum DSHSlashMatcher {
  /// The palette follows the leading token only, like the web `/` menu: a
  /// draft that starts with `/` and contains no whitespace yet. Returns the
  /// query (text after the slash, lowercased), nil when the palette should
  /// hide. IME marked text never reaches the binding, so composition-stage
  /// characters cannot open the palette (same limitation as the placeholder).
  static func bareToken(of draft: String) -> String? {
    guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return nil }
    return String(draft.dropFirst()).lowercased()
  }

  /// Build the visible roster for one query. Commands rank by the upstream
  /// fuzzy-discovery contract, simplified: prefix hits first, then remaining
  /// ordered-subsequence hits, catalog order within each band. Skills use
  /// prefix-only matching (the upstream skill source filters by
  /// `startsWith(query)`) and a name shared with a command resolves to the
  /// command — deliberate upstream precedence. Row count stays bounded so the
  /// palette never needs an inner scroller.
  static func entries(commands: [DSHCommandDescriptor], skills: [DSHSkillEntry], query: String) -> [DSHSlashEntry] {
    var commandEntries = commands.map { command in
      DSHSlashEntry(name: bare(command.name), description: command.description, kind: .command(hint: command.input?.hint))
    }
    // `/model` is a client-plane command upstream (a popup selector outside
    // the host registry); the native equivalent opens the composer's picker.
    if !commandEntries.contains(where: { $0.name == "model" }) {
      commandEntries.append(DSHSlashEntry(name: "model", description: "切换模型与推理强度", kind: .local(hint: nil)))
    }
    commandEntries.sort { $0.name < $1.name }

    var prefixHits: [DSHSlashEntry] = []
    var subsequenceHits: [DSHSlashEntry] = []
    for entry in commandEntries {
      if entry.name.hasPrefix(query) { prefixHits.append(entry) }
      else if isSubsequence(query, of: entry.name) { subsequenceHits.append(entry) }
    }
    let rankedCommands = prefixHits + subsequenceHits

    let commandNames = Set(rankedCommands.map(\.name))
    let skillSlots = max(0, 10 - rankedCommands.count)
    let skillEntries = skills.lazy
      .filter { !commandNames.contains($0.name) && $0.name.lowercased().hasPrefix(query) }
      .map { DSHSlashEntry(name: $0.name, description: $0.description, kind: .skill(userOnly: !$0.modelInvocable)) }
      .prefix(skillSlots)
    return rankedCommands + Array(skillEntries)
  }

  private static func bare(_ name: String) -> String {
    name.hasPrefix("/") ? String(name.dropFirst()).lowercased() : name.lowercased()
  }

  static func isSubsequence(_ query: String, of name: String) -> Bool {
    guard !query.isEmpty else { return true }
    var cursor = query.startIndex
    for character in name {
      if character == query[cursor] {
        cursor = query.index(after: cursor)
        if cursor == query.endIndex { return true }
      }
    }
    return false
  }
}

// MARK: - Palette view

/// Slash-command autocomplete above the input row: host commands and native
/// locals first, then the session's skills, with the keyboard-driven selection
/// highlight. Group titles appear only when both groups are present.
struct CommandPaletteView: View {
  let entries: [DSHSlashEntry]
  let selection: Int
  let onPick: (DSHSlashEntry) -> Void

  var body: some View {
    let firstSkillIndex = entries.firstIndex(where: \.isSkill)
    let showHeaders = firstSkillIndex.map { $0 > 0 } ?? false
    VStack(alignment: .leading, spacing: 2) {
      if showHeaders { header("指令") }
      ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
        if showHeaders, index == firstSkillIndex { header("技能") }
        row(entry, selected: index == selection)
      }
      Text("↑↓ 选择 · Tab 补全 · 回车执行 · Esc 关闭")
        .font(.caption2).foregroundStyle(DSHTheme.inkFaint)
        .padding(.horizontal, DSHSpace.s2).padding(.top, 2)
    }
    .padding(DSHSpace.s2)
    .dshCard(tint: DSHTheme.surfaceTint, radius: DSHRadius.md)
  }

  private func header(_ title: String) -> some View {
    Text(title).font(.caption2.weight(.semibold)).foregroundStyle(DSHTheme.inkFaint)
      .padding(.horizontal, DSHSpace.s2).padding(.top, 2)
  }

  private func row(_ entry: DSHSlashEntry, selected: Bool) -> some View {
    Button(action: { onPick(entry) }) {
      HStack(spacing: DSHSpace.s2) {
        Text("/\(entry.name)")
          .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
          .foregroundStyle(DSHTheme.accent)
        Text(entry.description).font(.caption2).foregroundStyle(DSHTheme.inkFaint).lineLimit(1)
        if case .skill(userOnly: true) = entry.kind { DSHBadge(text: "仅手动", tone: .neutral) }
        Spacer()
        if let hint = entry.hint { Text(hint).font(.caption2).foregroundStyle(DSHTheme.inkFaint) }
      }
      .padding(.vertical, 3).padding(.horizontal, DSHSpace.s2)
      .background(
        RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous)
          .fill(selected ? DSHTheme.accentSoft : Color.clear))
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Pick dispatch

extension HarnessController {
  /// Apply one palette pick, mirroring the web three-kind dispatch: a bare
  /// command executes immediately, a command with an input hint lands
  /// `/name ` for argument typing, a skill lands the literal `/name ` (the
  /// prompt ships the literal; expansion is host-side). `/export` and
  /// `/model` run their native equivalents — the registry's export handler is
  /// a web-plugin stub and `/model` never was a host command.
  func pickSlashEntry(_ entry: DSHSlashEntry) {
    switch entry.kind {
    case .command(let hint):
      if entry.name == "export" { draft = ""; exportCurrentSessionLog() }
      else if hint == nil { draft = "/\(entry.name)"; send() }
      else { draft = "/\(entry.name) " }
    case .skill:
      draft = "/\(entry.name) "
    case .local(let hint):
      if entry.name == "model" { draft = ""; showModelPicker = true }
      else if hint == nil { draft = "/\(entry.name)"; send() }
      else { draft = "/\(entry.name) " }
    }
  }
}

// MARK: - /model panel

/// Popover body behind `/model`: the same catalog the composer's model menu
/// reads (`llm.models` groups plus the adapter-advertised reasoning efforts),
/// rendered as tappable rows because a SwiftUI `Menu` cannot be opened
/// programmatically.
struct ModelPickerPanel: View {
  @EnvironmentObject var harness: HarnessController
  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s2) {
      if harness.availableModels.isEmpty {
        Text("尚未读到 Host 模型目录").font(.caption).foregroundStyle(DSHTheme.inkFaint)
        Button("刷新模型目录", action: harness.refreshModelConfiguration).buttonStyle(.dshSecondary)
      } else {
        ForEach(harness.availableModels) { group in
          Text(group.nativeDisplayName).font(.caption2.weight(.semibold)).foregroundStyle(DSHTheme.inkFaint)
          ForEach(group.models) { model in
            optionRow(model.name, selected: harness.provider == group.id && harness.model == model.id) {
              harness.selectCurrentModel(provider: group.id, model: model.id)
              harness.showModelPicker = false
            }
          }
        }
        if let reasoning = harness.currentModelEntry?.reasoning {
          Text("推理强度").font(.caption2.weight(.semibold)).foregroundStyle(DSHTheme.inkFaint).padding(.top, 2)
          ForEach(reasoning.efforts) { effort in
            optionRow(effort.name, selected: harness.reasoningEffort == effort.id) {
              harness.selectCurrentModel(provider: harness.provider, model: harness.model, reasoning: effort.id)
              harness.showModelPicker = false
            }
          }
        }
      }
    }
    .padding(DSHSpace.s3)
    .frame(minWidth: 220, alignment: .leading)
  }

  private func optionRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: DSHSpace.s2) {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 11)).foregroundStyle(selected ? DSHTheme.accent : DSHTheme.inkFaint)
        Text(title).font(.callout).foregroundStyle(DSHTheme.ink)
        Spacer()
      }
      .padding(.vertical, 3).padding(.horizontal, DSHSpace.s2)
      .background(
        RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous)
          .fill(selected ? DSHTheme.accentSoft : Color.clear))
    }
    .buttonStyle(.plain)
  }
}
