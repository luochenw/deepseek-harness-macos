import AppKit
import Foundation
import os

/// Non-crashing exception diagnostics: a swallowed `reportException` unwinds a
/// Swift concurrency job without a landing pad, so the process later dies at an
/// unrelated executor check (swiftlang/swift#89197) and the report never names
/// the exception. Logging name/reason/backtrace before calling the original
/// changes no control flow and degrades to "write nothing"; it names that
/// corruption, it does not prevent it.
enum DSHExceptionDiagnostics {
  /// `home` is a test seam so tests need not set `DSH_APP_HOME`.
  static func logURL(home: URL? = nil) -> URL {
    let dir = home ?? ProcessInfo.processInfo.environment["DSH_APP_HOME"].map {
      URL(fileURLWithPath: $0, isDirectory: true)
    } ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/DeepSeek Harness/dsh", isDirectory: true)
    return dir.appendingPathComponent("exception-diag.log")
  }

  /// A crash loop must not become a write storm.
  static let minimumInterval: TimeInterval = 1.0
  static let maximumBytes = 1_048_576
  static let maximumFrames = 40

  private static let logger = Logger(
    subsystem: "com.github.deepseek-harness-macos.app", category: "exception")
  private static let lock = NSLock()
  private static var installedClass: AnyClass?
  private static var lastWriteAt = Date.distantPast
  private static var suppressedSinceLastWrite = 0

  // MARK: - Rate limit / rotation / formatting (pure, unit-tested)

  /// A suppressed burst is counted so the next accepted line can report it.
  static func shouldWrite(now: Date, lastWrite: Date, minimumInterval: TimeInterval) -> Bool {
    now.timeIntervalSince(lastWrite) >= minimumInterval
  }

  /// One `.1` generation: these logs are for diagnosis, not archival.
  static func rotatedURL(for url: URL) -> URL {
    url.deletingLastPathComponent()
      .appendingPathComponent(url.lastPathComponent + ".1")
  }

  static func shouldRotate(currentBytes: Int, maximumBytes: Int) -> Bool {
    currentBytes > maximumBytes
  }

  /// Separate from the swizzle so the format is testable without AppKit.
  static func format(
    name: String,
    reason: String?,
    symbols: [String],
    thread: String,
    timestamp: Date,
    suppressed: Int = 0
  ) -> String {
    let formatter = ISO8601DateFormatter()
    var lines: [String] = []
    let dropped = suppressed > 0 ? " suppressed=\(suppressed)" : ""
    lines.append("=== \(formatter.string(from: timestamp)) thread=\(thread)\(dropped)")
    lines.append("name: \(name)")
    lines.append("reason: \(reason ?? "<nil>")")
    let frames = symbols.prefix(maximumFrames)
    lines.append("frames: \(symbols.count) shown: \(frames.count)")
    for (index, frame) in frames.enumerated() {
      // callStackSymbols prefixes its own index; keep one number per frame.
      lines.append("  #\(index) \(stripLeadingIndex(frame))")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// Drop the runtime's leading frame index, if present.
  static func stripLeadingIndex(_ frame: String) -> String {
    var rest = Substring(frame)
    var consumed = 0
    while let first = rest.first, first.isNumber, consumed < 4 {
      rest = rest.dropFirst()
      consumed += 1
    }
    guard consumed > 0, rest.first == " " || rest.first == "\t" else { return frame }
    return String(rest.drop(while: { $0 == " " || $0 == "\t" }))
  }

  // MARK: - Install

  /// Calling through the saved IMP preserves AppKit's implementation exactly.
  private typealias ReportExceptionFn =
    @convention(c) (AnyObject, Selector, NSException) -> Void

  private static var originalIMP: IMP?
  private static var installedTarget: AnyClass?
  /// Captured on the first install so a repeat does not see our own method.
  private static var originalOwner: AnyClass?

  /// Installs on the **actual class** of `NSApp` (SwiftUI builds
  /// `SwiftUI.AppKitApplication`, which inherits this selector). Not
  /// `method_exchangeImplementations`: that mutates `NSApplication` process-wide
  /// and a second install silently swaps the diagnostics back out, while
  /// `class_addMethod` on the subclass is idempotent and local to it.
  @discardableResult
  static func install() -> Bool {
    guard Thread.isMainThread else {
      logger.error("install skipped: not on the main thread")
      return false
    }
    guard let app = NSApp else {
      logger.error("install skipped: NSApp is nil")
      return false
    }
    guard let cls: AnyClass = object_getClass(app) else {
      logger.error("install skipped: NSApp has no class")
      return false
    }
    let selector = #selector(NSApplication.reportException(_:))
    guard let inherited = class_getInstanceMethod(cls, selector),
          let replacement = class_getMethodImplementation(cls, #selector(NSApplication.dsh_reportException(_:)))
    else {
      logger.error("install failed: reportException not found on \(NSStringFromClass(cls))")
      return false
    }
    let encoding = method_getTypeEncoding(inherited)

    // Before our copy exists, or the walk finds it and names the subclass.
    if originalOwner == nil {
      originalOwner = declaringClass(of: selector, startingAt: cls) ?? class_getSuperclass(cls) ?? cls
    }
    let owner = originalOwner ?? cls

    if class_addMethod(cls, selector, replacement, encoding) == false,
       let existing = class_getInstanceMethod(cls, selector) {
      // A real override or our earlier install: replace the IMP, never exchange.
      let previous = method_setImplementation(existing, replacement)
      if originalIMP == nil { originalIMP = previous }
    } else {
      // Our copy shadows the inherited method, whose IMP is what we must call.
      if originalIMP == nil { originalIMP = method_getImplementation(inherited) }
    }
    installedTarget = cls
    let line = "installed on \(NSStringFromClass(cls)) (implementation from \(NSStringFromClass(owner)))\n"
    // Through the same sink: this line is the proof the swizzle took.
    appendRaw(line)
    logger.notice("exception diagnostics installed on \(NSStringFromClass(cls), privacy: .public)")
    return isInstalled
  }

  /// The class in the hierarchy that actually declares `selector`.
  private static func declaringClass(of selector: Selector, startingAt cls: AnyClass) -> AnyClass? {
    var current: AnyClass? = cls
    while let candidate = current {
      var count: UInt32 = 0
      if let methods = class_copyMethodList(candidate, &count) {
        defer { free(methods) }
        for index in 0..<Int(count) where method_getName(methods[index]) == selector {
          return candidate
        }
      }
      current = class_getSuperclass(candidate)
    }
    return nil
  }

  /// True only when the live class runs **our** IMP, so an exchange cannot fake it.
  static var isInstalled: Bool {
    guard let target = installedTarget, let app = NSApp else { return false }
    guard object_getClass(app) === target else { return false }
    guard let method = class_getInstanceMethod(target, #selector(NSApplication.reportException(_:))),
          let ours = class_getMethodImplementation(target, #selector(NSApplication.dsh_reportException(_:)))
    else { return false }
    return method_getImplementation(method) == ours
  }

  /// Called from the installed IMP.
  static func callOriginal(_ app: AnyObject, _ selector: Selector, _ exception: NSException) {
    guard let imp = originalIMP else { return }
    let fn = unsafeBitCast(imp, to: ReportExceptionFn.self)
    fn(app, selector, exception)
  }

  // MARK: - Sink (best effort; never changes AppKit's control flow)

  /// The record is computed inline; the ~ms write is not.
  private static let writeQueue = DispatchQueue(label: "com.github.deepseek-harness-macos.app.exception-diag")

  /// Deadline, not a `defer`-reset flag: `defer` never runs on an ObjC unwind.
  private static var isLoggingUntil = Date.distantPast

  /// Called from the installed IMP; returns even if every write fails.
  static func record(name: String, reason: String?, symbols: [String]) {
    let now = Date()
    lock.lock()
    if now < isLoggingUntil {
      suppressedSinceLastWrite += 1
      lock.unlock()
      return
    }
    isLoggingUntil = now.addingTimeInterval(0.5)
    let allowed = shouldWrite(now: now, lastWrite: lastWriteAt, minimumInterval: minimumInterval)
    let suppressed = suppressedSinceLastWrite
    if allowed {
      lastWriteAt = now
      suppressedSinceLastWrite = 0
    } else {
      suppressedSinceLastWrite += 1
    }
    lock.unlock()
    guard allowed else { return }
    let rawName = Thread.current.name.flatMap { $0.isEmpty ? nil : $0 }
    let thread = Thread.isMainThread ? "main" : (rawName ?? "background")
    let text = format(
      name: name, reason: reason, symbols: symbols,
      thread: thread, timestamp: now, suppressed: suppressed)
    logger.error("swallowed exception name=\(name, privacy: .public) reason=\(reason ?? "<nil>", privacy: .public)")
    enqueueWrite(text)
  }

  /// Keeps the ~ms open/write/close off the caller (usually main).
  private static func enqueueWrite(_ text: String) {
    writeQueue.async {
      appendRaw(text)
    }
  }

  /// Keeps the file 0600 (`reason` holds user paths) and drops all errors.
  private static func appendRaw(_ text: String) {
    let url = logURL()
    let fm = FileManager.default
    do {
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let attributes = try? fm.attributesOfItem(atPath: url.path)
      let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
      if shouldRotate(currentBytes: size, maximumBytes: maximumBytes) {
        let rotated = rotatedURL(for: url)
        try? fm.removeItem(at: rotated)
        try? fm.moveItem(at: url, to: rotated)
      }
      guard let data = text.data(using: .utf8) else { return }
      if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
      } else {
        try? data.write(to: url)
      }
      // Every append: a rotated file inherits its mode, an older log may be 0644.
      try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      // Intentionally ignored.
    }
  }
}

extension NSApplication {
  /// Calls the saved original IMP (no exchange any more), so AppKit behaviour
  /// is unchanged.
  @objc func dsh_reportException(_ exception: NSException) {
    DSHExceptionDiagnostics.record(
      name: exception.name.rawValue,
      reason: exception.reason,
      symbols: exception.callStackSymbols)
    DSHExceptionDiagnostics.callOriginal(self, #selector(NSApplication.reportException(_:)), exception)
  }
}
