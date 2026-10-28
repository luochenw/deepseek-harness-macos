import Foundation

@testable import DSHAppLib

// DSHExceptionDiagnostics is the only non-crashing window into exceptions that
// AppKit swallows. Its sink must be exercisable without AppKit: rate limiting,
// rotation and the record format are pure functions, and a regression there
// silently loses the very evidence the crash hunt depends on.

private func testExceptionDiagnosticsRateLimit() throws {
  let base = Date(timeIntervalSince1970: 1_000)
  try expect(!DSHExceptionDiagnostics.shouldWrite(
    now: base, lastWrite: base, minimumInterval: 1.0),
    "two records in the same instant must collapse to one")
  try expect(DSHExceptionDiagnostics.shouldWrite(
    now: base.addingTimeInterval(1.0), lastWrite: base, minimumInterval: 1.0))
  try expect(DSHExceptionDiagnostics.shouldWrite(
    now: base.addingTimeInterval(30), lastWrite: base, minimumInterval: 1.0))
}

private func testExceptionDiagnosticsRotation() throws {
  try expect(!DSHExceptionDiagnostics.shouldRotate(currentBytes: 0, maximumBytes: 1024))
  try expect(DSHExceptionDiagnostics.shouldRotate(currentBytes: 1025, maximumBytes: 1024))
  let live = URL(fileURLWithPath: "/tmp/dsh/exception-diag.log")
  try expectEqual(DSHExceptionDiagnostics.rotatedURL(for: live).lastPathComponent,
                  "exception-diag.log.1")
  try expectEqual(DSHExceptionDiagnostics.rotatedURL(for: live).deletingLastPathComponent().path,
                  "/tmp/dsh")
}

private func testExceptionDiagnosticsFormat() throws {
  let text = DSHExceptionDiagnostics.format(
    name: "NSInternalInconsistencyException",
    reason: "required condition is false",
    symbols: (0..<60).map { "frame\($0)" },
    thread: "main",
    timestamp: Date(timeIntervalSince1970: 0),
    suppressed: 3)
  try expect(text.contains("thread=main"))
  try expect(text.contains("suppressed=3"))
  try expect(text.contains("name: NSInternalInconsistencyException"))
  try expect(text.contains("reason: required condition is false"))
  // Cap is 40 frames; the total is still reported so truncation is visible.
  try expect(text.contains("frames: 60 shown: 40"))
  try expect(text.contains("frame0"))
  try expect(!text.contains("frame40"))
  try expect(text.hasSuffix("\n"))
}

private func testExceptionDiagnosticsFormatWithoutReason() throws {
  let text = DSHExceptionDiagnostics.format(
    name: "NSGenericException", reason: nil, symbols: [], thread: "background",
    timestamp: Date(timeIntervalSince1970: 0))
  try expect(text.contains("reason: <nil>"))
  try expect(text.contains("frames: 0 shown: 0"))
  try expect(!text.contains("suppressed="))
}

private func testExceptionDiagnosticsStripsDuplicatedFrameIndex() throws {
  // callStackSymbols prefixes each line with its own index; the record adds one.
  try expectEqual(
    DSHExceptionDiagnostics.stripLeadingIndex("12   AppKit  0x1a0 __x + 8"),
    "AppKit  0x1a0 __x + 8")
  try expectEqual(DSHExceptionDiagnostics.stripLeadingIndex("0 CoreFoundation 0x1"), "CoreFoundation 0x1")
  // No leading index: unchanged.
  try expectEqual(DSHExceptionDiagnostics.stripLeadingIndex("AppKit 0x1"), "AppKit 0x1")
  // Digits that are part of the symbol are not eaten.
  try expectEqual(DSHExceptionDiagnostics.stripLeadingIndex("42"), "42")
}

private func testExceptionDiagnosticsLogPathLivesBesideVoiceDiag() throws {
  // Injected home: does not depend on DSH_APP_HOME being unset (other suites
  // set and restore it, so reading the environment here was flaky).
  let home = URL(fileURLWithPath: "/tmp/dsh-exception-diag-test/dsh", isDirectory: true)
  let url = DSHExceptionDiagnostics.logURL(home: home)
  try expectEqual(url.lastPathComponent, "exception-diag.log")
  try expectEqual(url.deletingLastPathComponent().path, home.path)
}

let dshExceptionDiagnosticsTests: [NamedTest] = [
  ("ExceptionDiagnostics collapses records inside the interval", testExceptionDiagnosticsRateLimit),
  ("ExceptionDiagnostics rotates past the size cap", testExceptionDiagnosticsRotation),
  ("ExceptionDiagnostics formats name/reason/frames", testExceptionDiagnosticsFormat),
  ("ExceptionDiagnostics formats a nil reason", testExceptionDiagnosticsFormatWithoutReason),
  ("ExceptionDiagnostics strips the duplicated frame index", testExceptionDiagnosticsStripsDuplicatedFrameIndex),
  ("ExceptionDiagnostics log sits beside voice-diag.log", testExceptionDiagnosticsLogPathLivesBesideVoiceDiag),
]
