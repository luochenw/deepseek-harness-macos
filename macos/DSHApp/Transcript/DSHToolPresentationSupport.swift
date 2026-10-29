import Foundation

struct DSHDisclosureWindow: Equatable {
  let head: Range<Int>
  let tail: Range<Int>
  let hiddenCount: Int
  let isCollapsed: Bool

  static func slice(count: Int, maxVisible: Int = 16, expanded: Bool) -> Self {
    let count = max(0, count)
    let maxVisible = max(1, maxVisible)
    guard !expanded, count > maxVisible else {
      return Self(head: 0..<count, tail: count..<count, hiddenCount: 0, isCollapsed: false)
    }

    let headCount = (maxVisible + 1) / 2
    let tailCount = maxVisible - headCount
    let tailStart = count - tailCount
    return Self(
      head: 0..<headCount,
      tail: tailStart..<count,
      hiddenCount: tailStart - headCount,
      isCollapsed: true)
  }
}

enum DSHTerminalStatus {
  static func label(exitCode: Int?, signal: String?, isRunning: Bool) -> String? {
    if let signal, !signal.isEmpty { return signal }
    if let exitCode { return "exit \(exitCode)" }
    return isRunning ? "运行中" : nil
  }
}

enum DSHToolPresentationLayout {
  static func showsFileActions(compact: Bool) -> Bool { !compact }
}

enum DSHToolPresentationURL {
  static func webURL(_ value: String) -> URL? {
    guard let url = URL(string: value),
          let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          url.host?.isEmpty == false else { return nil }
    return url
  }
}

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
  var state: HarnessController.ToolActivity.State
  var output: String
  var imageAttachments: [DSHAttachmentRef] = []
}

struct DSHSubcallPayload {
  let rootCallId: String
  let callId: String
  let name: String
  let title: String
  let arguments: String
}

enum DSHToolArguments {
  static func live(_ value: Any?) -> String? {
    if let text = value as? String {
      return text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }
    guard let value, JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys])
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func history(_ value: DSHJSONValue?) -> String? {
    guard let value else { return nil }
    if case .string(let text) = value {
      return text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }
    let any = anyValue(value)
    guard JSONSerialization.isValidJSONObject(any),
          let data = try? JSONSerialization.data(
            withJSONObject: any,
            options: [.prettyPrinted, .sortedKeys])
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func anyValue(_ value: DSHJSONValue) -> Any {
    switch value {
    case .string(let value): value
    case .number(let value): value
    case .bool(let value): value
    case .object(let value): value.mapValues(anyValue)
    case .array(let value): value.map(anyValue)
    case .null: NSNull()
    }
  }
}

enum DSHSubcallDecoder {
  static func live(from data: [String: Any]) -> DSHSubcallPayload? {
    guard let rootCallId = callID(data["rootCallId"]) ?? callID(data["parentCallId"]),
          let callId = callID(data["subCallId"]),
          let name = data["name"] as? String else { return nil }
    let object = data["arguments"] as? [String: Any]
    let rawArguments = data["arguments"] as? String
    let parsed = object ?? rawArguments.flatMap(parseObject)
    return DSHSubcallPayload(
      rootCallId: rootCallId,
      callId: callId,
      name: name,
      title: title(name: name, arguments: parsed, fallback: rawArguments),
      arguments: prettyJSON(object ?? parsed) ?? rawArguments ?? "")
  }

  static func history(from data: [String: DSHJSONValue]) -> DSHSubcallPayload? {
    guard let rootCallId = data["rootCallId"]?.string ?? data["parentCallId"]?.string,
          let callId = data["subCallId"]?.string,
          let name = data["name"]?.string else { return nil }
    let object = data["arguments"]?.object?.mapValues(anyValue)
    let rawArguments = data["arguments"]?.string
    let parsed = object ?? rawArguments.flatMap(parseObject)
    return DSHSubcallPayload(
      rootCallId: rootCallId,
      callId: callId,
      name: name,
      title: title(name: name, arguments: parsed, fallback: rawArguments),
      arguments: prettyJSON(object ?? parsed) ?? rawArguments ?? "")
  }

  static func output(from value: Any?) -> String {
    DSHToolContentText.live(value)
  }

  static func output(from value: DSHJSONValue?) -> String {
    DSHToolContentText.history(value)
  }

  static func instructionTitle(name: String, arguments: String) -> String? {
    resolvedTitle(
      name: name,
      arguments: parseObject(arguments),
      fallback: arguments)
  }

  private static func callID(_ value: Any?) -> String? {
    (value as? String).flatMap { $0.isEmpty ? nil : $0 }
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

  private static func anyValue(_ value: DSHJSONValue) -> Any {
    switch value {
    case .string(let value): value
    case .number(let value): value
    case .bool(let value): value
    case .object(let value): value.mapValues(anyValue)
    case .array(let value): value.map(anyValue)
    case .null: NSNull()
    }
  }
}

extension HarnessController.ToolActivity {
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
    incoming: [HarnessController.ToolActivity],
    previous: [HarnessController.ToolActivity]
  ) -> [HarnessController.ToolActivity] {
    incoming.map { tool in
      guard let old = previous.last(where: { $0.callId == tool.callId }) else { return tool }
      return merging(incoming: tool, previous: old)
    }
  }

  static func merging(
    incoming: HarnessController.ToolActivity,
    previous: HarnessController.ToolActivity
  ) -> HarnessController.ToolActivity {
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

struct DSHToolGroupStatusSummary: Equatable {
  let detail: String?
  let running: Bool
  let failed: Bool
}

enum DSHToolGroupStatus {
  static func summary(
    for activities: [HarnessController.ToolActivity]
  ) -> DSHToolGroupStatusSummary? {
    guard let latest = activities.last else { return nil }
    return DSHToolGroupStatusSummary(
      detail: instructionTitle(for: latest),
      running: activities.contains { $0.state == .running },
      failed: activities.contains { $0.state == .failed })
  }

  static func instructionTitle(for activity: HarnessController.ToolActivity) -> String? {
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
  static func shellCommand(for activity: HarnessController.ToolActivity) -> String? {
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

struct DSHToolInstruction: Identifiable {
  enum Source {
    case activity(HarnessController.ToolActivity)
    case child(DSHToolChildActivity)
  }

  let id: String
  let title: String
  let state: HarnessController.ToolActivity.State
  let output: String
  let source: Source
  /// Mutating calls paint their row in the theme accent and get a pencil.
  var mutating: Bool = false
}

enum DSHToolInstructionFlatten {
  static func instructions(
    from activities: [HarnessController.ToolActivity]
  ) -> [DSHToolInstruction] {
    var instructions: [DSHToolInstruction] = []
    var seen = Set<String>()

    for activity in activities {
      if activity.children.isEmpty {
        guard let title = DSHToolGroupStatus.instructionTitle(for: activity) else {
          continue
        }
        let id = "activity:\(activity.callId)"
        if seen.insert(id).inserted {
          instructions.append(DSHToolInstruction(
            id: id,
            title: title,
            state: activity.state,
            output: activity.output,
            source: .activity(activity),
            mutating: activity.callKind.isMutating))
        }
        continue
      }

      let instructionCountBeforeChildren = instructions.count
      for child in activity.children {
        let id = "child:\(activity.callId):\(child.callId)"
        guard seen.insert(id).inserted else { continue }
        guard let title = DSHToolGroupStatus.instructionTitle(for: child) else {
          continue
        }
        instructions.append(DSHToolInstruction(
          id: id,
          title: title,
          state: child.state,
          output: child.output,
          source: .child(child),
          mutating: DSHToolCallClassifier
            .kind(name: child.name, arguments: child.arguments)
            .isMutating))
      }
      if instructions.count == instructionCountBeforeChildren,
         let title = DSHToolGroupStatus.instructionTitle(for: activity) {
        let id = "activity:\(activity.callId)"
        if seen.insert(id).inserted {
          instructions.append(DSHToolInstruction(
            id: id,
            title: title,
            state: activity.state,
            output: activity.output,
            source: .activity(activity),
            mutating: activity.callKind.isMutating))
        }
      }
    }
    return instructions
  }
}

enum DSHToolJobState {
  static func resolve(_ status: String) -> HarnessController.ToolActivity.State {
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
  static func live(_ value: Any?) -> String {
    switch value {
    case let text as String:
      return text
    case let blocks as [[String: Any]]:
      return blocks.map(live).filter { !$0.isEmpty }.joined()
    case let values as [Any]:
      return values.map(live).filter { !$0.isEmpty }.joined()
    case let block as [String: Any]:
      if block["type"] as? String == "text", let text = block["text"] as? String {
        return text
      }
      return live(block["content"])
    default:
      return ""
    }
  }

  static func history(_ value: DSHJSONValue?) -> String {
    guard let value else { return "" }
    switch value {
    case .string(let text):
      return text
    case .array(let values):
      return values.map { history($0) }.filter { !$0.isEmpty }.joined()
    case .object(let block):
      if block["type"]?.string == "text", let text = block["text"]?.string {
        return text
      }
      return history(block["content"])
    case .number, .bool, .null:
      return ""
    }
  }
}

enum DSHToolResultDecoder {
  static func live(from data: [String: Any]) -> DSHToolResultPayload? {
    if let message = data["message"] as? [String: Any],
       let callId = (message["source"] as? [String: Any])?["callId"] as? String
        ?? message["toolCallId"] as? String,
       let blocks = message["content"] as? [[String: Any]] {
      if let result = blocks.first(where: { $0["type"] as? String == "tool-result" }) {
        let content = result["content"] as? [[String: Any]] ?? []
        return DSHToolResultPayload(
          callId: callId,
          output: DSHToolContentText.live(content),
          isError: (result["isError"] as? Bool ?? false) || data["error"] != nil,
          errorSummary: errorSummary(data["error"]),
          imageAttachments: DSHAttachmentRef.fromLiveContent(content))
      }
      return DSHToolResultPayload(
        callId: callId,
        output: DSHToolContentText.live(blocks),
        isError: (message["isError"] as? Bool ?? false) || data["error"] != nil,
        errorSummary: errorSummary(data["error"]),
        imageAttachments: DSHAttachmentRef.fromLiveContent(blocks))
    }

    guard let callId = data["callId"] as? String else { return nil }
    return DSHToolResultPayload(
      callId: callId,
      output: DSHToolContentText.live(data["result"]),
      isError: data["error"] != nil,
      errorSummary: errorSummary(data["error"]),
      imageAttachments: [])
  }

  static func history(from data: [String: DSHJSONValue]) -> DSHToolResultPayload? {
    if let message = data["message"]?.object,
       let callId = message["source"]?.object?["callId"]?.string
        ?? message["toolCallId"]?.string,
       let blocks = message["content"]?.array {
      if let result = blocks.compactMap(\.object).first(where: { $0["type"]?.string == "tool-result" }) {
        let content = result["content"]?.array ?? []
        return DSHToolResultPayload(
          callId: callId,
          output: DSHToolContentText.history(.array(content)),
          isError: historyBool(result["isError"]) || data["error"] != nil,
          errorSummary: errorSummary(data["error"]),
          imageAttachments: DSHAttachmentRef.fromHistoryContent(content))
      }
      return DSHToolResultPayload(
        callId: callId,
        output: DSHToolContentText.history(.array(blocks)),
        isError: historyBool(message["isError"]) || data["error"] != nil,
        errorSummary: errorSummary(data["error"]),
        imageAttachments: DSHAttachmentRef.fromHistoryContent(blocks))
    }

    guard let callId = data["callId"]?.string else { return nil }
    return DSHToolResultPayload(
      callId: callId,
      output: DSHToolContentText.history(data["result"]),
      isError: data["error"] != nil,
      errorSummary: errorSummary(data["error"]),
      imageAttachments: [])
  }

  private static func historyBool(_ value: DSHJSONValue?) -> Bool {
    guard case let .bool(flag)? = value else { return false }
    return flag
  }

  private static func errorSummary(_ value: Any?) -> String? {
    guard let error = value as? [String: Any] else { return nil }
    let code = error["code"] as? String
    let name = error["name"] as? String
    return [name, code].compactMap { $0 }.joined(separator: " · ").nonEmpty
  }

  private static func errorSummary(_ value: DSHJSONValue?) -> String? {
    guard let error = value?.object else { return nil }
    return [error["name"]?.string, error["code"]?.string]
      .compactMap { $0 }
      .joined(separator: " · ")
      .nonEmpty
  }
}

extension HarnessController.ToolPresentation {
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

  static func fromHistoryToolCall(name: String, arguments: DSHJSONValue?) -> Self? {
    if let value = arguments?.string {
      return fromToolCall(name: name, arguments: value)
    }
    guard let object = arguments?.object else { return nil }
    let any = Dictionary(uniqueKeysWithValues: object.map { ($0.key, toolAnyValue($0.value)) })
    return fromToolCall(name: name, arguments: any)
  }

  static func fromEventView(_ eventView: [String: Any]?) -> Self? {
    guard let eventView else { return nil }
    var raw = (eventView["view"] as? [String: Any]) ?? eventView
    if raw["output"] == nil {
      raw["output"] = DSHToolContentText.live(raw["content"]).nonEmpty
    }
    return from(raw)
  }

  static func fromEventView(_ eventView: DSHJSONValue?) -> Self? {
    guard let object = eventView?.object else { return nil }
    let embedded = object["view"]?.object ?? object
    var raw = Dictionary(uniqueKeysWithValues: embedded.map { ($0.key, toolAnyValue($0.value)) })
    if raw["output"] == nil {
      raw["output"] = DSHToolContentText.history(embedded["content"]).nonEmpty
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

  private static func toolAnyValue(_ value: DSHJSONValue) -> Any {
    switch value {
    case .string(let value): value
    case .number(let value): value
    case .bool(let value): value
    case .object(let value): Dictionary(uniqueKeysWithValues: value.map { ($0.key, toolAnyValue($0.value)) })
    case .array(let value): value.map(toolAnyValue)
    case .null: NSNull()
    }
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

enum DSHSourceTokenKind: Equatable {
  case plain
  case keyword
  case string
  case number
  case comment
  case key
}

struct DSHSourceToken: Equatable {
  let kind: DSHSourceTokenKind
  let text: String
}

enum DSHSourceTokenizer {
  static func tokens(in text: String, language: String?) -> [DSHSourceToken] {
    let language = normalizedLanguage(language)
    guard let language else { return [DSHSourceToken(kind: .plain, text: text)] }
    var state = State.normal
    return tokenize(text, language: language, state: &state)
  }

  static func tokens(in lines: [String], language: String?) -> [[DSHSourceToken]] {
    let language = normalizedLanguage(language)
    guard let language else {
      return lines.map { [DSHSourceToken(kind: .plain, text: $0)] }
    }

    var state = State.normal
    return lines.map { tokenize($0, language: language, state: &state) }
  }

  private enum State {
    case normal
    case blockComment
    case string(Character)
    case tripleQuotedString
  }

  private static func tokenize(_ text: String, language: String, state: inout State) -> [DSHSourceToken] {
    guard !text.isEmpty else { return [] }

    let characters = Array(text)
    var tokens: [DSHSourceToken] = []
    var index = 0

    func append(_ kind: DSHSourceTokenKind, _ text: String) {
      guard !text.isEmpty else { return }
      if let last = tokens.last, last.kind == kind {
        tokens[tokens.count - 1] = DSHSourceToken(kind: kind, text: last.text + text)
      } else {
        tokens.append(DSHSourceToken(kind: kind, text: text))
      }
    }

    while index < characters.count {
      switch state {
      case .blockComment:
        let start = index
        while index + 1 < characters.count,
              !(characters[index] == "*" && characters[index + 1] == "/") {
          index += 1
        }
        if index + 1 < characters.count {
          index += 2
          state = .normal
        } else {
          index = characters.count
        }
        append(.comment, String(characters[start..<index]))
        continue
      case .string(let quote):
        let start = index
        while index < characters.count {
          if characters[index] == "\\" {
            index = min(characters.count, index + 2)
            continue
          }
          if characters[index] == quote {
            index += 1
            state = .normal
            break
          }
          index += 1
        }
        append(.string, String(characters[start..<index]))
        continue
      case .tripleQuotedString:
        let start = index
        while index + 2 < characters.count,
              !(characters[index] == "\"" && characters[index + 1] == "\"" && characters[index + 2] == "\"") {
          index += 1
        }
        if index + 2 < characters.count {
          index += 3
          state = .normal
        } else {
          index = characters.count
        }
        append(.string, String(characters[start..<index]))
        continue
      case .normal:
        break
      }

      let current = characters[index]
      if startsLineComment(characters, at: index, language: language) {
        let start = index
        while index < characters.count, characters[index] != "\n" { index += 1 }
        append(.comment, String(characters[start..<index]))
        continue
      }

      if startsBlockComment(characters, at: index, language: language) {
        let start = index
        index += 2
        while index + 1 < characters.count,
              !(characters[index] == "*" && characters[index + 1] == "/") {
          index += 1
        }
        if index + 1 < characters.count {
          index += 2
        } else {
          index = characters.count
          state = .blockComment
        }
        append(.comment, String(characters[start..<index]))
        continue
      }

      if startsTripleQuotedString(characters, at: index, language: language) {
        let start = index
        index += 3
        while index + 2 < characters.count,
              !(characters[index] == "\"" && characters[index + 1] == "\"" && characters[index + 2] == "\"") {
          index += 1
        }
        if index + 2 < characters.count {
          index += 3
        } else {
          index = characters.count
          state = .tripleQuotedString
        }
        append(.string, String(characters[start..<index]))
        continue
      }

      if isQuote(current, language: language) {
        let start = index
        let quote = current
        index += 1
        while index < characters.count {
          if characters[index] == "\\" {
            index = min(characters.count, index + 2)
            continue
          }
          if characters[index] == quote {
            index += 1
            break
          }
          index += 1
        }
        let string = String(characters[start..<index])
        append(isJSONKey(characters, after: index, language: language) ? .key : .string, string)
        if index == characters.count, characters.last != quote {
          state = .string(quote)
        }
        continue
      }

      if isDigit(current) {
        let start = index
        index += 1
        while index < characters.count,
              isDigit(characters[index]) || characters[index] == "." || characters[index] == "_" {
          index += 1
        }
        append(.number, String(characters[start..<index]))
        continue
      }

      if isIdentifierStart(current) {
        let start = index
        index += 1
        while index < characters.count, isIdentifierContinue(characters[index]) { index += 1 }
        let identifier = String(characters[start..<index])
        append(keywords(for: language).contains(identifier) ? .keyword : .plain, identifier)
        continue
      }

      append(.plain, String(current))
      index += 1
    }

    return tokens
  }

  private static func normalizedLanguage(_ value: String?) -> String? {
    switch value?.lowercased() {
    case "swift", "ts", "tsx", "typescript", "js", "jsx", "javascript",
         "python", "py", "json", "bash", "sh", "zsh", "yaml", "yml",
         "md", "markdown":
      return value?.lowercased()
    default:
      return nil
    }
  }

  private static func keywords(for language: String) -> Set<String> {
    switch language {
    case "swift":
      return [
        "actor", "as", "async", "await", "case", "catch", "class", "deinit",
        "default", "else", "enum", "extension", "false", "final", "for",
        "func", "guard", "if", "import", "in", "init", "internal", "is",
        "let", "nil", "private", "protocol", "public", "return", "static",
        "struct", "switch", "throw", "true", "try", "var", "where", "while",
      ]
    case "ts", "tsx", "typescript", "js", "jsx", "javascript":
      return [
        "as", "async", "await", "break", "case", "catch", "class", "const",
        "continue", "default", "else", "export", "extends", "false", "finally",
        "for", "from", "function", "if", "import", "in", "instanceof",
        "interface", "let", "new", "null", "private", "public", "readonly",
        "return", "static", "switch", "throw", "true", "try", "type",
        "undefined", "var", "while",
      ]
    case "python", "py":
      return [
        "False", "None", "True", "and", "as", "async", "await", "break",
        "class", "continue", "def", "elif", "else", "except", "finally",
        "for", "from", "if", "import", "in", "is", "lambda", "not", "or",
        "pass", "raise", "return", "try", "while", "with", "yield",
      ]
    case "bash", "sh", "zsh":
      return [
        "case", "do", "done", "echo", "elif", "else", "esac", "export",
        "fi", "for", "function", "if", "in", "local", "readonly", "return",
        "then", "while",
      ]
    case "json":
      return ["false", "null", "true"]
    case "yaml", "yml":
      return ["false", "null", "true", "yes", "no"]
    default:
      return []
    }
  }

  private static func startsLineComment(_ characters: [Character], at index: Int, language: String) -> Bool {
    if supportsSlashComments(language),
       index + 1 < characters.count,
       characters[index] == "/",
       characters[index + 1] == "/" {
      return true
    }
    return supportsHashComments(language) && characters[index] == "#"
  }

  private static func startsBlockComment(_ characters: [Character], at index: Int, language: String) -> Bool {
    supportsSlashComments(language)
      && index + 1 < characters.count
      && characters[index] == "/"
      && characters[index + 1] == "*"
  }

  private static func supportsSlashComments(_ language: String) -> Bool {
    ["swift", "ts", "tsx", "typescript", "js", "jsx", "javascript"].contains(language)
  }

  private static func supportsHashComments(_ language: String) -> Bool {
    ["python", "py", "bash", "sh", "zsh", "yaml", "yml"].contains(language)
  }

  private static func isQuote(_ character: Character, language: String) -> Bool {
    character == "\"" || character == "'" || (["ts", "tsx", "typescript", "js", "jsx", "javascript", "bash", "sh", "zsh"].contains(language) && character == "`")
  }

  private static func startsTripleQuotedString(_ characters: [Character], at index: Int, language: String) -> Bool {
    language == "swift"
      && index + 2 < characters.count
      && characters[index] == "\""
      && characters[index + 1] == "\""
      && characters[index + 2] == "\""
  }

  private static func isJSONKey(_ characters: [Character], after index: Int, language: String) -> Bool {
    guard language == "json" else { return false }
    var index = index
    while index < characters.count, characters[index].isWhitespace { index += 1 }
    return index < characters.count && characters[index] == ":"
  }

  private static func isDigit(_ character: Character) -> Bool {
    character.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
  }

  private static func isIdentifierStart(_ character: Character) -> Bool {
    character == "_" || character == "$" || character.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
  }

  private static func isIdentifierContinue(_ character: Character) -> Bool {
    isIdentifierStart(character) || isDigit(character)
  }
}
