import Foundation
@testable import DSHAppLib

private func testDisclosureWindow_keepsHeadAndTailAroundHiddenMiddle() throws {
  let window = DSHDisclosureWindow.slice(count: 19, maxVisible: 16, expanded: false)

  try expect(window.isCollapsed)
  try expectEqual(window.head, 0..<8)
  try expectEqual(window.tail, 11..<19)
  try expectEqual(window.hiddenCount, 3)
}

private func testDisclosureWindow_doesNotCollapseAtOrBelowBudget() throws {
  let exact = DSHDisclosureWindow.slice(count: 16, maxVisible: 16, expanded: false)
  try expect(!exact.isCollapsed)
  try expectEqual(exact.head, 0..<16)
  try expectEqual(exact.tail, 16..<16)
  try expectEqual(exact.hiddenCount, 0)

  let expanded = DSHDisclosureWindow.slice(count: 48, maxVisible: 16, expanded: true)
  try expect(!expanded.isCollapsed)
  try expectEqual(expanded.head, 0..<48)
  try expectEqual(expanded.tail, 48..<48)
  try expectEqual(expanded.hiddenCount, 0)
}

private func testSourceTokenizer_classifiesSwiftKeywordsNumbersAndComments() throws {
  let tokens = DSHSourceTokenizer.tokens(in: "let value = 42 // note", language: "swift")

  try expect(tokens.contains { $0.kind == .keyword && $0.text == "let" })
  try expect(tokens.contains { $0.kind == .number && $0.text == "42" })
  try expect(tokens.contains { $0.kind == .comment && $0.text == "// note" })
}

private func testSourceTokenizer_preservesStringBeforeCommentMarker() throws {
  let tokens = DSHSourceTokenizer.tokens(in: #"let url = "https://example.test" // note"#, language: "swift")

  try expect(tokens.contains { $0.kind == .string && $0.text == #""https://example.test""# })
  try expect(tokens.contains { $0.kind == .comment && $0.text == "// note" })
  try expect(!tokens.contains { $0.kind == .comment && $0.text.contains("https://") })
}

private func testSourceTokenizer_marksJSONKeysAndFallsBackToPlaintext() throws {
  let json = DSHSourceTokenizer.tokens(in: #"{"enabled": true, "count": 2}"#, language: "json")
  try expect(json.contains { $0.kind == .key && $0.text == #""enabled""# })
  try expect(json.contains { $0.kind == .number && $0.text == "2" })

  let unknown = DSHSourceTokenizer.tokens(in: "opaque text", language: "fortran")
  try expectEqual(unknown, [DSHSourceToken(kind: .plain, text: "opaque text")])
}

private func testTerminalStatus_preservesSuccessfulExitCode() throws {
  try expectEqual(
    DSHTerminalStatus.label(exitCode: 0, signal: nil, isRunning: false),
    "exit 0")
  try expectEqual(
    DSHTerminalStatus.label(exitCode: 17, signal: nil, isRunning: false),
    "exit 17")
  try expectEqual(
    DSHTerminalStatus.label(exitCode: nil, signal: "SIGTERM", isRunning: false),
    "SIGTERM")
  try expectEqual(
    DSHTerminalStatus.label(exitCode: nil, signal: nil, isRunning: true),
    "运行中")
}

private func testToolPresentationLayout_preservesDetailsFileActions() throws {
  try expect(DSHToolPresentationLayout.showsFileActions(compact: false))
  try expect(!DSHToolPresentationLayout.showsFileActions(compact: true))
}

private func testToolPresentationURL_allowsOnlyAbsoluteHTTPURLs() throws {
  try expectEqual(DSHToolPresentationURL.webURL("https://example.com/path")?.host, "example.com")
  try expectEqual(DSHToolPresentationURL.webURL("http://example.com")?.scheme, "http")
  try expect(DSHToolPresentationURL.webURL("file:///tmp/private.txt") == nil)
  try expect(DSHToolPresentationURL.webURL("mailto:test@example.com") == nil)
  try expect(DSHToolPresentationURL.webURL("custom://example.com") == nil)
  try expect(DSHToolPresentationURL.webURL("/relative/path") == nil)
}

private func testSourceTokenizer_carriesBlockCommentAcrossLines() throws {
  let tokens = DSHSourceTokenizer.tokens(
    in: ["let value = 1 /* starts", "still comment", "ends */ let next = 2"],
    language: "swift")

  try expect(tokens[1].allSatisfy { $0.kind == .comment })
  try expect(tokens[2].first?.kind == .comment)
  try expect(tokens[2].contains { $0.kind == .keyword && $0.text == "let" })
  try expect(tokens[2].contains { $0.kind == .number && $0.text == "2" })
}

private func testSourceTokenizer_carriesStringAcrossLines() throws {
  let tokens = DSHSourceTokenizer.tokens(
    in: ["let value = \"first", "second\" // done"],
    language: "swift")

  try expect(tokens[1].first?.kind == .string)
  try expect(tokens[1].contains { $0.kind == .comment && $0.text == "// done" })
}

private func testSourceTokenizer_carriesSwiftTripleQuotedStringAcrossLines() throws {
  let tokens = DSHSourceTokenizer.tokens(
    in: ["let value = \"\"\"first", "still text", "end\"\"\" // done"],
    language: "swift")

  try expect(tokens[1].allSatisfy { $0.kind == .string })
  try expect(tokens[2].first?.kind == .string)
  try expect(tokens[2].contains { $0.kind == .comment && $0.text == "// done" })
}

let dshToolPresentationTests: [NamedTest] = [
  ("Disclosure window keeps head and tail around hidden middle", testDisclosureWindow_keepsHeadAndTailAroundHiddenMiddle),
  ("Disclosure window does not collapse at or below budget", testDisclosureWindow_doesNotCollapseAtOrBelowBudget),
  ("Source tokenizer classifies Swift keywords, numbers, and comments", testSourceTokenizer_classifiesSwiftKeywordsNumbersAndComments),
  ("Source tokenizer preserves string before comment marker", testSourceTokenizer_preservesStringBeforeCommentMarker),
  ("Source tokenizer marks JSON keys and falls back to plaintext", testSourceTokenizer_marksJSONKeysAndFallsBackToPlaintext),
  ("Terminal status preserves successful exit code", testTerminalStatus_preservesSuccessfulExitCode),
  ("Tool presentation layout preserves details file actions", testToolPresentationLayout_preservesDetailsFileActions),
  ("Tool presentation URL allows only absolute HTTP URLs", testToolPresentationURL_allowsOnlyAbsoluteHTTPURLs),
  ("Source tokenizer carries block comments across lines", testSourceTokenizer_carriesBlockCommentAcrossLines),
  ("Source tokenizer carries strings across lines", testSourceTokenizer_carriesStringAcrossLines),
  ("Source tokenizer carries Swift triple-quoted strings across lines", testSourceTokenizer_carriesSwiftTripleQuotedStringAcrossLines),
]
