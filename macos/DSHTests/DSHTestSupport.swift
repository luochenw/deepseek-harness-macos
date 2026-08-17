import Foundation

/// Minimal assert harness for `./scripts/test-macos-native.sh --unit` — no
/// XCTest (this project deliberately has no Xcode/SwiftPM project, see
/// `.agents/notes/implemented/architecture/2026-08-14-no-xcode-project.md`).
/// Each test file lists its own `NamedTest`s explicitly in DSHTestsMain.swift
/// rather than auto-discovering — Swift has no reflection-based test
/// discovery without a framework, and explicit listing is easier to audit.

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

typealias NamedTest = (name: String, body: () throws -> Void)

@discardableResult
func runAll(_ tests: [NamedTest]) -> Bool {
  var failures: [(name: String, message: String)] = []
  for test in tests {
    do {
      try test.body()
    } catch {
      failures.append((test.name, "\(error)"))
    }
  }
  let passed = tests.count - failures.count
  print("Ran \(tests.count) test(s): \(passed) passed, \(failures.count) failed")
  for failure in failures {
    print("  FAIL \(failure.name): \(failure.message)")
  }
  return failures.isEmpty
}
