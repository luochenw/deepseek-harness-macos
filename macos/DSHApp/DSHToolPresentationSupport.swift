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
       let source = message["source"] as? [String: Any],
       let callId = source["callId"] as? String,
       let blocks = message["content"] as? [[String: Any]],
       let result = blocks.first(where: { $0["type"] as? String == "tool-result" }) {
      let content = result["content"] as? [[String: Any]] ?? []
      return DSHToolResultPayload(
        callId: callId,
        output: DSHToolContentText.live(content),
        isError: (result["isError"] as? Bool ?? false) || data["error"] != nil,
        errorSummary: errorSummary(data["error"]))
    }

    guard let callId = data["callId"] as? String else { return nil }
    return DSHToolResultPayload(
      callId: callId,
      output: DSHToolContentText.live(data["result"]),
      isError: data["error"] != nil,
      errorSummary: errorSummary(data["error"]))
  }

  static func history(from data: [String: DSHJSONValue]) -> DSHToolResultPayload? {
    if let message = data["message"]?.object,
       let source = message["source"]?.object,
       let callId = source["callId"]?.string,
       let blocks = message["content"]?.array,
       let result = blocks.compactMap(\.object).first(where: { $0["type"]?.string == "tool-result" }) {
      let content = result["content"]?.array ?? []
      return DSHToolResultPayload(
        callId: callId,
        output: DSHToolContentText.history(.array(content)),
        isError: historyBool(result["isError"]) || data["error"] != nil,
        errorSummary: errorSummary(data["error"]))
    }

    guard let callId = data["callId"]?.string else { return nil }
    return DSHToolResultPayload(
      callId: callId,
      output: DSHToolContentText.history(data["result"]),
      isError: data["error"] != nil,
      errorSummary: errorSummary(data["error"]))
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
