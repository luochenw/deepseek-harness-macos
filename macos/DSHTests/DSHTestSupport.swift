import Foundation
@testable import DSHAppLib

/// Minimal assert harness for `./scripts/test-macos-native.sh --unit` — no
/// XCTest (this project deliberately has no Xcode/SwiftPM project, see
/// `.agents/notes/implemented/architecture/2026-08-14-no-xcode-project.md`).
/// Each test file lists its own `NamedTest`s explicitly in DSHTestsMain.swift
/// rather than auto-discovering — Swift has no reflection-based test
/// discovery without a framework, and explicit listing is easier to audit.

/// Decodes a test payload the way a Host frame is decoded, so numbers arrive as
/// JSON numbers rather than as the Swift `Int` literals a test happened to write.
func decodedObject(_ value: [String: Any]) -> [String: DSHJSONValue] {
  DSHProjectionDecoder.decode(DSHJSONValue.self, from: value)?.object ?? [:]
}

extension DSHRawEvent {
  /// Hand-written test events may omit `seq` or `time`.
  init?(frame: [String: Any]) {
    guard let type = frame["type"] as? String,
          let data = frame["data"].flatMap({ DSHProjectionDecoder.decode(DSHJSONValue.self, from: $0) })
    else { return nil }
    self.init(
      type: type,
      seq: frame["seq"] as? Int ?? -1,
      time: (frame["time"] as? NSNumber)?.doubleValue ?? -1,
      data: data)
  }
}

enum TestFailure: Error, CustomStringConvertible {
  case message(String)
  var description: String {
    switch self { case .message(let text): return text }
  }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) throws {
  guard condition() else {
    let detail = message()
    throw TestFailure.message("\(file):\(line)" + (detail.isEmpty ? "" : " — \(detail)"))
  }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) throws {
  try expect(actual == expected, "expected \(expected), got \(actual)", file: file, line: line)
}

func expectThrows(
  _ body: () throws -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) throws {
  do {
    try body()
  } catch {
    return
  }
  throw TestFailure.message("\(file):\(line) — expected an error")
}

typealias NamedTest = (name: String, body: () throws -> Void)

/// Thrown by a test whose real-session fixture is not on this machine. The
/// fixtures are local-only (see `macos/DSHTests/Fixtures/README.md`), so a clean
/// checkout has no copy; the test must then be reported as skipped, not failed.
enum TestSkip: Error, CustomStringConvertible {
  case message(String)
  var description: String {
    switch self { case .message(let text): return text }
  }
}

@discardableResult
func runAll(_ tests: [NamedTest]) -> Bool {
  var failures: [(name: String, message: String)] = []
  var skipped: [(name: String, message: String)] = []
  for test in tests {
    do {
      try test.body()
    } catch let skip as TestSkip {
      skipped.append((test.name, skip.description))
    } catch {
      failures.append((test.name, "\(error)"))
    }
  }
  let passed = tests.count - failures.count - skipped.count
  print("Ran \(tests.count) test(s): \(passed) passed, \(skipped.count) skipped,"
        + " \(failures.count) failed")
  for skip in skipped {
    print("  SKIP \(skip.name): \(skip.message)")
  }
  for failure in failures {
    print("  FAIL \(failure.name): \(failure.message)")
  }
  return failures.isEmpty
}
