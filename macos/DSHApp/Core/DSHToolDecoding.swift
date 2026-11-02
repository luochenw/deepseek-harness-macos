import Foundation

enum DSHToolPresentationNumber {
  static func integerValue(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? Double, value.rounded() == value { return Int(value) }
    return nil
  }
}

struct DSHToolResultPayload: Equatable {
  let callId: String
  let output: String
  let isError: Bool
  let errorSummary: String?
  let imageAttachments: [DSHAttachmentRef]
}

struct DSHToolChildActivity: Identifiable {
  let id = UUID()
  let callId: String
  let name: String
  let title: String
  let arguments: String
  var state: DSHToolActivity.State
  var output: String
  var imageAttachments: [DSHAttachmentRef] = []
}

struct DSHSubcallPayload {
  /// Absent on some Code Mode dispatches. Those cannot join a tool row, but the
  /// workbench still acts on them.
  let rootCallId: String?
  let callId: String
  let name: String
  let title: String
  let arguments: String
}

enum DSHToolArguments {
  static func decode(_ value: DSHJSONValue?) -> String? {
    guard let value else { return nil }
    if case .string(let text) = value {
      return text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }
    let any = value.plainValue
    guard JSONSerialization.isValidJSONObject(any),
          let data = try? JSONSerialization.data(
            withJSONObject: any,
            options: [.prettyPrinted, .sortedKeys])
    else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

enum DSHSubcallDecoder {
  static func decode(from data: [String: DSHJSONValue]) -> DSHSubcallPayload? {
    guard let callId = callID(data["subCallId"]),
          let name = data["name"]?.string else { return nil }
    let object = data["arguments"]?.object?.mapValues(\.plainValue)
    let rawArguments = data["arguments"]?.string
    let parsed = object ?? rawArguments.flatMap(parseObject)
    return DSHSubcallPayload(
      rootCallId: callID(data["rootCallId"]) ?? callID(data["parentCallId"]),
      callId: callId,
      name: name,
      title: title(name: name, arguments: parsed, fallback: rawArguments),
      arguments: prettyJSON(object ?? parsed) ?? rawArguments ?? "")
  }

  static func output(from value: DSHJSONValue?) -> String {
    DSHToolContentText.text(value)
  }

  static func instructionTitle(name: String, arguments: String) -> String? {
    resolvedTitle(
      name: name,
      arguments: parseObject(arguments),
      fallback: arguments)
  }

  private static func callID(_ value: DSHJSONValue?) -> String? {
    value?.string?.nonEmpty
  }

  private static func title(
    name: String,
    arguments: [String: Any]?,
    fallback: String?
  ) -> String {
    resolvedTitle(name: name, arguments: arguments, fallback: fallback) ?? name
  }

  private static func resolvedTitle(
    name: String,
    arguments: [String: Any]?,
    fallback: String?
  ) -> String? {
    guard let arguments else {
      return meaningfulFallback(fallback)
    }
    if let friendly = DSHJobToolCopy.title(for: name) {
      return friendly
    }
    switch name {
    case "bash", "shell", "sh", "zsh":
      guard let command = (arguments["command"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
        // No command at all: still never blank — say what ran, not nothing.
        return meaningfulFallback(fallback) ?? "运行命令"
      }
      return DSHCommandTitle.summarize(command).title
    case "read", "write", "edit", "read_image":
      return ((arguments["file_path"] as? String)
        ?? (arguments["path"] as? String))?.nonEmpty
    case "glob":
      return (arguments["pattern"] as? String)?.nonEmpty
    case "grep":
      let pattern = arguments["pattern"] as? String ?? ""
      let path = arguments["path"] as? String
      return ([pattern.nonEmpty, path].compactMap { $0 }).joined(separator: " · ").nonEmpty
    case "web_fetch":
      return (arguments["url"] as? String)?.nonEmpty
    case "web_search":
      return (arguments["queries"] as? [String])?
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
        .nonEmpty
    case "todo_write":
      return "\((arguments["todos"] as? [Any])?.count ?? 0) 项任务"
    case "skill":
      return (arguments["name"] as? String)?.nonEmpty
    case "apply_patch":
      return patchInstruction(from: arguments["patch"] as? String)
    default:
      return genericInstruction(name: name, arguments: arguments)
        ?? meaningfulFallback(fallback)
    }
  }

  private static func genericInstruction(
    name: String,
    arguments: [String: Any]
  ) -> String? {
    let preferredKeys = [
      "description", "prompt", "command", "file_path", "path",
      "pattern", "query", "queries", "url", "name", "label", "action",
    ]
    let remainingKeys = arguments.keys
      .filter { !preferredKeys.contains($0) && !["code", "content", "output"].contains($0) }
      .sorted()

    for key in preferredKeys + remainingKeys {
      guard let value = argumentText(arguments[key]) else { continue }
      if ["description", "prompt", "action"].contains(key) {
        return value
      }
      return "\(name) · \(value)"
    }
    return nil
  }

  private static func argumentText(_ value: Any?) -> String? {
    switch value {
    case let text as String:
      return text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    case let values as [String]:
      return values.filter { !$0.isEmpty }.joined(separator: " · ").nonEmpty
    case let values as [Any]:
      return values.compactMap(argumentText).joined(separator: " · ").nonEmpty
    default:
      return nil
    }
  }

  private static func meaningfulFallback(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let trimmed = trimmed.nonEmpty else { return nil }
    if ["{}", "[]", "null", "undefined"].contains(trimmed.lowercased()) {
      return nil
    }
    if trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
       (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil {
      return nil
    }
    return String(trimmed.prefix(180))
  }

  private static func patchInstruction(from patch: String?) -> String? {
    guard let patch else { return nil }
    for line in patch.split(whereSeparator: \.isNewline) {
      for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] {
        if line.hasPrefix(prefix) {
          return String(line.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        }
      }
    }
    return nil
  }

  private static func parseObject(_ value: String) -> [String: Any]? {
    guard let data = value.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private static func prettyJSON(_ value: [String: Any]?) -> String? {
    guard let value,
          let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys]) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

extension DSHToolActivity {
  /// Ends a tool the turn left running, along with any child still open under it.
  mutating func settle(as settled: State) {
    state = settled
    for child in children.indices where children[child].state == .running {
      children[child].state = settled
    }
  }

  mutating func startChild(_ subcall: DSHSubcallPayload) {
    if let index = children.lastIndex(where: { $0.callId == subcall.callId }) {
      children[index] = DSHToolChildActivity(
        callId: subcall.callId,
        name: subcall.name,
        title: subcall.title,
        arguments: subcall.arguments,
        state: .running,
        output: "")
    } else {
      children.append(DSHToolChildActivity(
        callId: subcall.callId,
        name: subcall.name,
        title: subcall.title,
        arguments: subcall.arguments,
        state: .running,
        output: ""))
    }
  }

  mutating func finishChild(
    _ subcall: DSHSubcallPayload,
    output: String,
    failed: Bool,
    imageAttachments: [DSHAttachmentRef] = []
  ) {
    let state: State = failed ? .failed : .succeeded
    if let index = children.lastIndex(where: { $0.callId == subcall.callId }) {
      children[index].state = state
      children[index].output = output
      children[index].imageAttachments = imageAttachments
    } else {
      children.append(DSHToolChildActivity(
        callId: subcall.callId,
        name: subcall.name,
        title: subcall.title,
        arguments: subcall.arguments,
        state: state,
        output: output,
        imageAttachments: imageAttachments))
    }
  }
}

enum DSHToolActivityMerge {
  static func preservingDetails(
    incoming: [DSHToolActivity],
    previous: [DSHToolActivity]
  ) -> [DSHToolActivity] {
    incoming.map { tool in
      guard let old = previous.last(where: { $0.callId == tool.callId }) else { return tool }
      return merging(incoming: tool, previous: old)
    }
  }

  /// A snapshot carries only the recent tail. When it merges into rows already on
  /// screen, the tools behind those earlier rows stay, or their rows cannot expand.
  static func mergingTail(
    _ incoming: [DSHToolActivity],
    into previous: [DSHToolActivity]
  ) -> [DSHToolActivity] {
    let incomingIDs = Set(incoming.map(\.callId))
    return previous.filter { !incomingIDs.contains($0.callId) }
      + preservingDetails(incoming: incoming, previous: previous)
  }

  static func merging(
    incoming: DSHToolActivity,
    previous: DSHToolActivity
  ) -> DSHToolActivity {
    var tool = incoming
    if tool.presentation == nil { tool.presentation = previous.presentation }
    if tool.children.isEmpty { tool.children = previous.children }
    if tool.imageAttachments.isEmpty { tool.imageAttachments = previous.imageAttachments }
    if tool.arguments?.nonEmpty == nil { tool.arguments = previous.arguments }
    if tool.output.isEmpty || tool.output == "工具已完成" {
      tool.output = previous.output.nonEmpty ?? tool.output
    }
    if tool.summary == "工具调用" || tool.summary == "正在运行" {
      tool.summary = previous.summary
    }
    return tool
  }
}

enum DSHToolJobState {
  static func resolve(_ status: String) -> DSHToolActivity.State {
    switch status.lowercased() {
    case "completed", "succeeded":
      return .succeeded
    case "failed", "killed", "cancelled", "canceled":
      return .failed
    default:
      return .running
    }
  }
}

enum DSHToolContentText {
  static func text(_ value: DSHJSONValue?) -> String {
    guard let value else { return "" }
    switch value {
    case .string(let text):
      return text
    case .array(let values):
      return values.map { text($0) }.filter { !$0.isEmpty }.joined()
    case .object(let block):
      if block["type"]?.string == "text", let text = block["text"]?.string {
        return text
      }
      return text(block["content"])
    case .number, .bool, .null:
      return ""
    }
  }
}

enum DSHToolResultDecoder {
  static func decode(from data: [String: DSHJSONValue]) -> DSHToolResultPayload? {
    if let message = data["message"]?.object,
       let callId = message["source"]?.object?["callId"]?.string
        ?? message["toolCallId"]?.string,
       let blocks = message["content"]?.array {
      if let result = blocks.compactMap(\.object).first(where: { $0["type"]?.string == "tool-result" }) {
        let content = result["content"]?.array ?? []
        return DSHToolResultPayload(
          callId: callId,
          output: DSHToolContentText.text(.array(content)),
          isError: result["isError"]?.bool == true || data["error"] != nil,
          errorSummary: errorSummary(data["error"]),
          imageAttachments: DSHAttachmentRef.fromContent(content))
      }
      return DSHToolResultPayload(
        callId: callId,
        output: DSHToolContentText.text(.array(blocks)),
        isError: message["isError"]?.bool == true || data["error"] != nil,
        errorSummary: errorSummary(data["error"]),
        imageAttachments: DSHAttachmentRef.fromContent(blocks))
    }

    guard let callId = data["callId"]?.string else { return nil }
    return DSHToolResultPayload(
      callId: callId,
      output: DSHToolContentText.text(data["result"]),
      isError: data["error"] != nil,
      errorSummary: errorSummary(data["error"]),
      imageAttachments: [])
  }

  private static func errorSummary(_ value: DSHJSONValue?) -> String? {
    guard let error = value?.object else { return nil }
    return [error["name"]?.string, error["code"]?.string]
      .compactMap { $0 }
      .joined(separator: " · ")
      .nonEmpty
  }
}

extension DSHToolPresentation {
  static func fromToolCall(name: String, arguments: Any?) -> Self? {
    let object: [String: Any]?
    if let arguments = arguments as? [String: Any] {
      object = arguments
    } else if let arguments = arguments as? String,
              let data = arguments.data(using: .utf8) {
      object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    } else {
      object = nil
    }
    switch name {
    case "run_code":
      guard let code = object?["code"] as? String, !code.isEmpty else { return nil }
      return from([
        "card": "code",
        "title": object?["description"] as? String ?? "run_code",
        "description": code,
        "lang": "typescript",
      ])
    case "read_image":
      guard let path = ((object?["file_path"] as? String)
        ?? (object?["path"] as? String))?.nonEmpty else { return nil }
      return from([
        "card": "image",
        "title": path,
        "path": path,
      ])
    default:
      return nil
    }
  }

  static func fromDecodedToolCall(name: String, arguments: DSHJSONValue?) -> Self? {
    guard name == "run_code" || name == "read_image" else { return nil }
    if let value = arguments?.string {
      return fromToolCall(name: name, arguments: value)
    }
    guard let object = arguments?.object else { return nil }
    return fromToolCall(name: name, arguments: object.mapValues(\.plainValue))
  }

  static func fromEventView(_ eventView: DSHJSONValue?) -> Self? {
    guard let object = eventView?.object else { return nil }
    let embedded = object["view"]?.object ?? object
    var raw = embedded.mapValues(\.plainValue)
    if raw["output"] == nil {
      raw["output"] = DSHToolContentText.text(embedded["content"]).nonEmpty
    }
    return from(raw)
  }

  static func merging(
    call: Self?,
    result: Self?,
    rawOutput: String
  ) -> Self? {
    guard let call else {
      guard let result else { return nil }
      return result.withOutput(result.output?.nonEmpty ?? rawOutput.nonEmpty)
    }
    guard let result else {
      return call.withOutput(call.output?.nonEmpty ?? rawOutput.nonEmpty)
    }

    let resultIsGeneric = result.card == "generic"
    let resultSuppliesStructuredCard = !resultIsGeneric
    return Self(
      card: resultSuppliesStructuredCard ? result.card : call.card,
      title: result.title ?? call.title,
      path: resultSuppliesStructuredCard ? (result.path ?? call.path) : call.path,
      output: result.output?.nonEmpty ?? rawOutput.nonEmpty ?? call.output,
      exitCode: result.exitCode ?? call.exitCode,
      signal: result.signal ?? call.signal,
      cwd: result.cwd ?? call.cwd,
      description: result.description ?? call.description,
      diffs: result.diffs.isEmpty ? call.diffs : result.diffs,
      lines: result.lines.isEmpty ? call.lines : result.lines,
      totalLines: result.totalLines ?? call.totalLines,
      lang: result.lang ?? call.lang,
      searchShape: result.searchShape ?? call.searchShape,
      files: result.files.isEmpty ? call.files : result.files,
      paths: result.paths.isEmpty ? call.paths : result.paths,
      truncated: resultSuppliesStructuredCard ? result.truncated : call.truncated,
      total: result.total ?? call.total,
      webKind: result.webKind ?? call.webKind,
      answer: result.answer ?? call.answer,
      url: result.url ?? call.url,
      statusCode: result.statusCode ?? call.statusCode,
      sources: result.sources.isEmpty ? call.sources : result.sources)
  }

  fileprivate func withOutput(_ output: String?) -> Self {
    Self(
      card: card,
      title: title,
      path: path,
      output: output,
      exitCode: exitCode,
      signal: signal,
      cwd: cwd,
      description: description,
      diffs: diffs,
      lines: lines,
      totalLines: totalLines,
      lang: lang,
      searchShape: searchShape,
      files: files,
      paths: paths,
      truncated: truncated,
      total: total,
      webKind: webKind,
      answer: answer,
      url: url,
      statusCode: statusCode,
      sources: sources)
  }
}

extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}

struct DSHToolGroupStatusSummary: Equatable {
  let detail: String?
  let running: Bool
  let failed: Bool
}

enum DSHToolGroupStatus {
  static func summary(
    for activities: [DSHToolActivity]
  ) -> DSHToolGroupStatusSummary? {
    guard let latest = activities.last else { return nil }
    return DSHToolGroupStatusSummary(
      detail: instructionTitle(for: latest),
      running: activities.contains { $0.state == .running },
      failed: activities.contains { $0.state == .failed })
  }

  static func instructionTitle(for activity: DSHToolActivity) -> String? {
    // Shell rows are summarized from the whole command string, not its first
    // line: a `cd … && python3 - <<'PY'` heredoc has no readable first line
    // (it is a directory change), which is what produced blank-looking rows.
    if DSHToolCallShape.isShellTool(activity.name),
       let command = shellCommand(for: activity) {
      return DSHCommandTitle.summarize(command).title
    }
    if let friendly = DSHJobToolCopy.title(for: activity.name) {
      return friendly
    }
    let presentation = activity.presentation
    let directCandidates = [
      activity.children.last.flatMap { instructionTitle(for: $0) },
      presentation?.title,
      presentation?.path,
    ]
    for candidate in directCandidates {
      if let title = meaningfulText(candidate),
         title.caseInsensitiveCompare(activity.name) != .orderedSame {
        return title
      }
    }

    if presentation?.card != "code",
       let description = meaningfulText(presentation?.description) {
      return description
    }

    if let summary = meaningfulText(activity.summary),
       !["工具调用", "正在运行", "工具已完成"].contains(summary) {
      return summary
    }

    if let arguments = activity.arguments,
       let title = DSHSubcallDecoder.instructionTitle(
         name: activity.name,
         arguments: arguments) {
      return title
    }

    if presentation?.card == "code" {
      if let instruction = codeInstruction(from: presentation?.description) {
        return instruction
      }
    }
    // Never return nil for a command tool: an unanswered title is exactly what
    // rendered as an empty terminal row.
    return DSHToolCallShape.isCommandTool(activity.name)
      ? DSHToolCallShape.fallbackTitle(for: activity.name)
      : nil
  }

  static func instructionTitle(for child: DSHToolChildActivity) -> String? {
    if DSHToolCallShape.isShellTool(child.name),
       let command = commandString(from: child.arguments) {
      return DSHCommandTitle.summarize(command).title
    }
    if let title = meaningfulText(child.title),
       title.caseInsensitiveCompare(child.name) != .orderedSame {
      return title
    }
    return DSHSubcallDecoder.instructionTitle(
      name: child.name,
      arguments: child.arguments)
  }

  /// The raw shell command for an activity: the argument payload when the App
  /// kept it, otherwise the Host-projected `presentation.title` (the bash tool
  /// projects its full `command` there).
  static func shellCommand(for activity: DSHToolActivity) -> String? {
    if let command = commandString(from: activity.arguments) { return command }
    guard let title = activity.presentation?.title,
          !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return title
  }

  static func commandString(from arguments: String?) -> String? {
    guard let arguments,
          let data = arguments.data(using: .utf8),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let command = object["command"] as? String,
          !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return command
  }

  private static func meaningfulText(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if ["{}", "[]", "null", "undefined"].contains(trimmed.lowercased()) {
      return nil
    }
    if trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
       (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil {
      return nil
    }
    let firstLine = trimmed.split(whereSeparator: \.isNewline)
      .first
      .map(String.init)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let firstLine, !firstLine.isEmpty else { return nil }
    return String(firstLine.prefix(180))
  }

  private static func codeInstruction(from source: String?) -> String? {
    guard let source else { return nil }
    let pattern = #"tools\.([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\{\s*(?:command|file_path|path|pattern|url)\s*:\s*["']([^"']+)["']"#
    guard let expression = try? NSRegularExpression(
      pattern: pattern,
      options: [.dotMatchesLineSeparators]),
          let match = expression.firstMatch(
            in: source,
            range: NSRange(source.startIndex..., in: source)),
          let nameRange = Range(match.range(at: 1), in: source),
          let argumentRange = Range(match.range(at: 2), in: source)
    else { return nil }
    let name = String(source[nameRange])
    let argument = String(source[argumentRange])
    return "\(name) · \(argument)"
  }
}
