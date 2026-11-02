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
