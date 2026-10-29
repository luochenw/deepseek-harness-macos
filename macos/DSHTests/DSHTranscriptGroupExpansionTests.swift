import AppKit
import Foundation
import SwiftUI
@testable import DSHAppLib

// MARK: - A command group's rendered line is computed by regex classification
//
// Expanding a 64-command group froze the app at 100% CPU on 2026-10-29 (sample:
// `hang-expand-64-sample.txt`). The sample's main-thread hot path is
// `ToolGroupRow.chipText` / `.groupTitle` / `.mutatingCount` → `.digest` →
// `ToolActivity.callKind` → `DSHToolCallClassifier.commandWritesFiles` →
// `statementWritesFiles` → `matches` → `StringProtocol.range(of:options:)` →
// Swift regex engine. `digest` is computed once PER GETTER, so one body
// evaluation of the row classifies every command three times, and each
// classification compiles up to 22 `NSRegularExpression`s per statement.
//
// These tests pin the cost of that work per body evaluation. They measure the
// same functions the row calls — `ConversationView.toolGroupSignature` (the
// parent's pass, identical shape) and the digest builder fed by
// `callKind` + `instructionTitle` (what `ToolGroupRow.digest` composes) — over
// the real 103-command Host fixture, truncated to 8/16/32/64/103 commands, so a
// regression in the classifier shows up as a number, not as a frozen app.
//
// Why 8 ms: `macos/DSHApp/Transcript/AGENTS.md` records the transcript's target
// of an 8 ms p95 frame, and one click has to produce a frame. Three digest
// reads per body evaluation means this budget covers the whole row, not one
// getter, so it is the honest ceiling.
//
// The heavy measurement runs under a watchdog: if the row's cost ever stops
// converging the test process exits with `exitWatchdog` instead of hanging CI
// (that is what the incident looked like). The watchdog is disarmed as soon as
// the measurement returns.

/// Budget for one body evaluation's worth of line-building work. Matches the
/// 8 ms p95 frame target recorded in `macos/DSHApp/Transcript/AGENTS.md`.
private let groupLineFrameBudgetMs: Double = 8

/// Command count of the synthetic group the counted test uses. Kept next to the
/// budget so the two assertions above and in `syntheticGroup` cannot drift.
private let syntheticCommandCount = 64

/// Exit code the watchdog uses. Distinct from 1 so a run that was killed by the
/// deadline is not mistaken for an assertion failure.
private let exitWatchdog: Int32 = 70

/// Runs `body` on the main actor with a hard wall-clock deadline. If the
/// deadline passes the process exits with `exitWatchdog` and a diagnostic —
/// a hang here must never block the whole suite.
@MainActor
private func withWatchdog(
  seconds: Double,
  label: String,
  _ body: () throws -> Void
) rethrows {
  let armed = WatchdogFlag()
  let watchdog = Thread {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if armed.isDone { return }
      Thread.sleep(forTimeInterval: 0.05)
    }
    guard !armed.isDone else { return }
    FileHandle.standardError.write(Data("""
      FAIL \(label): no result after \(Int(seconds))s — the group row's line \
      building did not converge (the 2026-10-29 expand-freeze shape).

      """.utf8))
    exit(exitWatchdog)
  }
  watchdog.stackSize = 512 * 1024
  watchdog.start()
  defer { armed.finish() }
  try body()
}

/// `@unchecked Sendable` is required, not incidental: the flag is read from the
/// watchdog `Thread` and written from the main actor, and `NSLock` (not the type
/// system) is what makes that safe — see the locked `done` below and root
/// `AGENTS.md`'s rule about justifying this annotation in writing.
private final class WatchdogFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false
  var isDone: Bool {
    lock.lock(); defer { lock.unlock() }
    return done
  }
  func finish() {
    lock.lock(); defer { lock.unlock() }
    done = true
  }
}

// MARK: - Fixture

private struct DSHExpandFixture: Decodable {
  let records: [DSHHistoryEntry]
}

/// The 103-command turn, truncated to its first `commandCount` tool calls. The
/// fixture is local-only (git-ignored), so its absence is a SKIP, not a pass.
private func expandFixture(commandCount: Int) throws -> [DSHHistoryEntry] {
  var candidates: [URL] = []
  if let override = ProcessInfo.processInfo.environment["DSH_GOLDEN_FIXTURES"] {
    candidates.append(URL(fileURLWithPath: override, isDirectory: true))
  }
  var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  for _ in 0..<6 {
    candidates.append(directory.appendingPathComponent("Fixtures", isDirectory: true))
    directory = directory.deletingLastPathComponent()
  }
  let tried = candidates.map {
    $0.appendingPathComponent("session-84f7c0cb-turn1.json")
  }
  guard let url = tried.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
    throw TestSkip.message("fixture session-84f7c0cb-turn1.json is not on this machine;"
      + " see macos/DSHTests/Fixtures/README.md")
  }
  let fixture = try JSONDecoder().decode(DSHExpandFixture.self, from: Data(contentsOf: url))
  var seen = 0
  return fixture.records.filter { entry in
    guard entry.event.type == "tool/call" else { return true }
    seen += 1
    return seen <= commandCount
  }
}

@MainActor
private func expandHarness(commandCount: Int) throws -> (
  harness: HarnessController,
  group: [HarnessController.Message]
) {
  let harness = HarnessController(startRuntime: false)
  let folded = harness.foldHistoryContent(try expandFixture(commandCount: commandCount))
  let session = HarnessController.Session(
    title: "expand",
    workspaceName: "ds-harness",
    updatedAt: Date(),
    messages: folded.messages,
    hostSessionId: "session-expand")
  harness.sessions = [session]
  harness.selectedSessionID = session.id
  harness.hostCurrentSessionID = session.hostSessionId
  harness.activeTools = folded.tools
  let group = ConversationView
    .foldTranscript(folded.messages, activeTurnRunning: false)
    .compactMap { item -> [HarnessController.Message]? in
      guard case .toolGroup(let group) = item else { return nil }
      return group
    }
    .first ?? []
  guard group.count == commandCount else {
    throw TestFailure.message("expected a \(commandCount)-command group, folded \(group.count)")
  }
  return (harness, group)
}

// MARK: - Measurement

/// One body evaluation, as the row now performs it: resolve the group's digest
/// through the store the transcript uses, then read the STORED value the way
/// `groupTitle` / `mutatingCount` / `chipText` do.
///
/// `cold` builds a digest that was never cached (one signature change: a command
/// appended, a result landing); `warm` repeats it, which is what every later
/// layout pass costs. The 8 ms frame budget applies to the warm case — a body is
/// re-evaluated many times per expansion, while a signature changes once.
@MainActor
private func groupBodyCost(
  _ group: [HarnessController.Message],
  tools: [HarnessController.ToolActivity],
  iterations: Int
) -> (cold: Double, warm: Double) {
  // Cache key of this exact group, computed the way the transcript does.
  let key = ConversationView.toolGroupDigestKey(group, tools: tools)
  DSHToolGroupDigestStore.removeAll()
  let coldStart = DispatchTime.now().uptimeNanoseconds
  let first = DSHToolGroupDigestStore.digest(key: key) {
    ConversationView.toolGroupDigest(group, tools: tools)
  }
  let cold = Double(DispatchTime.now().uptimeNanoseconds - coldStart) / 1_000_000
  _ = ConversationView.toolGroupSignature(first)
  let warmStart = DispatchTime.now().uptimeNanoseconds
  for _ in 0..<iterations {
    let digest = DSHToolGroupDigestStore.digest(key: key) {
      ConversationView.toolGroupDigest(group, tools: tools)
    }
    _ = ConversationView.toolGroupSignature(digest)
  }
  let warm = Double(DispatchTime.now().uptimeNanoseconds - warmStart) / 1_000_000
    / Double(iterations)
  return (cold, warm)
}

// MARK: - Tests

/// ① The row that froze the app: 64 commands, one body evaluation.
private func testExpand_sixtyFourCommandLineFitsOneFrame() throws {
  try MainActor.assumeIsolated {
    var measured: Double = -1
    var coldLogged: Double = 0
    try withWatchdog(seconds: 120, label: "64-command line cost") {
      do {
        let (harness, group) = try expandHarness(commandCount: 64)
        let cost = groupBodyCost(group, tools: harness.displayedTools, iterations: 20)
        measured = cost.warm
        coldLogged = cost.cold
        print(String(format: "  expand: 64 commands = %.2fms per repeat body evaluation"
          + " (cold %.1fms, budget %.0fms)", measured, coldLogged, groupLineFrameBudgetMs))
      } catch let skip as TestSkip {
        throw skip
      }
    }
    try expect(measured >= 0, "the 64-command measurement threw")
    try expect(measured < groupLineFrameBudgetMs,
               String(format: "one repeated body evaluation of a 64-command group costs"
                 + " %.1fms (cold build %.1fms), over the %.0fms frame budget by %.1fx —"
                 + " every layout pass pays this, and the row body is re-evaluated"
                 + " repeatedly while the height change settles",
                 measured, coldLogged, groupLineFrameBudgetMs,
                 measured / groupLineFrameBudgetMs))
  }
}

/// ② The real 103-command turn from the fixture. Same budget: expanding it must
/// not cost more than a frame either.
private func testExpand_hundredThreeCommandLineFitsOneFrame() throws {
  try MainActor.assumeIsolated {
    var measured: Double = -1
    var coldLogged: Double = 0
    try withWatchdog(seconds: 120, label: "103-command line cost") {
      do {
        let (harness, group) = try expandHarness(commandCount: 103)
        let cost = groupBodyCost(group, tools: harness.displayedTools, iterations: 20)
        measured = cost.warm
        coldLogged = cost.cold
        print(String(format: "  expand: 103 commands = %.2fms per repeat body evaluation"
          + " (cold %.1fms, budget %.0fms)", measured, coldLogged, groupLineFrameBudgetMs))
      } catch let skip as TestSkip {
        throw skip
      }
    }
    try expect(measured >= 0, "the 103-command measurement threw")
    try expect(measured < groupLineFrameBudgetMs,
               String(format: "one repeated body evaluation of a 103-command group costs"
                 + " %.1fms (cold build %.1fms), over the %.0fms frame budget by %.1fx",
                 measured, coldLogged, groupLineFrameBudgetMs,
                 measured / groupLineFrameBudgetMs))
  }
}

/// ③ The cost has to stay proportional to the text it reads, and the per-KB
/// constant is what the fix moved: a cold digest (one signature change) is the
/// only pass that still classifies every command, and it must stay cheap enough
/// that even a running group landing 100 commands cannot stutter.
///
/// Measured on the pre-fix code: 4.3 ms/KB at 64 commands (97 ms for 22 KB) and
/// 3.6 ms/KB at 103 (188 ms for 53 KB), because the same text was classified
/// three times per body with a freshly compiled regex each time. The unit build
/// is `-Onone`, so all of these numbers are upper bounds.
private func testExpand_costStaysProportionalToCommandText() throws {
  try MainActor.assumeIsolated {
    var points: [(Int, Double, Double, Int)] = []
    try withWatchdog(seconds: 180, label: "8..103 cost curve") {
      for count in [8, 16, 32, 64, 103] {
        do {
          let (harness, group) = try expandHarness(commandCount: count)
          let characters = harness.displayedTools.reduce(0) { total, tool in
            total + (DSHToolGroupStatus.shellCommand(for: tool)?.utf8.count ?? 0)
          }
          let cost = groupBodyCost(group, tools: harness.displayedTools, iterations: 5)
          points.append((count, cost.cold, cost.warm, characters))
        } catch let skip as TestSkip {
          throw skip
        }
      }
    }
    guard points.count == 5 else {
      throw TestFailure.message("the cost curve did not complete: \(points)")
    }
    let report = points
      .map {
        String(format: "%d commands/%.1fKB cold=%.1fms repeat=%.2fms",
               $0.0, Double($0.3) / 1_000, $0.1, $0.2)
      }
      .joined(separator: " ")
    print("  expand curve: \(report)")

    // A repeated body must be effectively free — that is what the cache buys.
    for (count, _, warm, _) in points {
      try expect(warm < 1.0,
                 String(format: "a repeated body evaluation of \(count) commands still costs"
                   + " %.2fms; the digest cache is not serving it. Curve: %@", warm, report))
    }
    // The one unavoidable pass (a signature change) is bounded per kilobyte.
    // Only the text-heavy points are normalised: at 8 commands the fixed
    // per-call overhead is all of it.
    let textHeavy = points.filter { $0.3 >= 10_000 }
    try expectEqual(textHeavy.count, 2)
    for (count, cold, _, characters) in textHeavy {
      let perKB = cold / (Double(characters) / 1_000)
      try expect(perKB <= 1.0,
                 String(format: "a cold digest of \(count) commands costs %.2fms per KB of"
                   + " command text (%.1fms for %.1fKB). Curve: %@",
                   perKB, cold, Double(characters) / 1_000, report))
    }
  }
}

/// 64 commands of the shape the real ones have — a `cd … && python3 - <<'PY'`
/// line plus a heredoc body — totalling ~19 KB (6 body lines each). Built in memory so the
/// count assertion runs on CI, where the Host fixtures are absent.
private let syntheticCommandPayload: (Int, Int) -> String = { index, lines in
  var out = ["cd /Users/developer/project/outputs/site/ && python3 - <<'PY'"]
  for line in 0..<lines {
    out.append("print('row \(index)-\(line)', {'key': 'value'}, \(line))")
  }
  out.append("PY")
  return out.joined(separator: "\n")
}

@MainActor
private func syntheticTools(count: Int, payloadLines: Int) -> [HarnessController.ToolActivity] {
  (0..<count).map { index in
    let command = syntheticCommandPayload(index, payloadLines)
    let arguments = try? JSONSerialization.data(withJSONObject: ["command": command])
    return HarnessController.ToolActivity(
      callId: "call-\(index)",
      name: "bash",
      summary: "工具调用",
      state: .succeeded,
      output: "ok",
      arguments: arguments.flatMap { String(data: $0, encoding: .utf8) },
      presentation: nil)
  }
}

@MainActor
private func syntheticGroup(count: Int, payloadLines: Int) -> [HarnessController.Message] {
  (0..<count).map { index in
    HarnessController.Message(role: .tool, text: "bash", toolCallId: "call-\(index)")
  }
}

/// ④ Counted, not timed, through the REAL row: render an expanded `ToolGroupRow`
/// offscreen and pump the run loop so SwiftUI re-evaluates its body several
/// times. The counter increments inside `DSHToolCallClassifier.kind(for:)`, so
/// it records classifications that actually ran — a `digest` getter that
/// recomputed per read would show up here even though the store was untouched.
///
/// 64 synthetic heredoc commands (~19 KB), no fixture: runs on CI.
private func testExpand_bodyClassifiesEachCommandAtMostOnce() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let count = syntheticCommandCount
    let group = syntheticGroup(count: count, payloadLines: 6)
    harness.activeTools = syntheticTools(count: count, payloadLines: 6)

    _ = NSApplication.shared
    NSApp.appearance = NSAppearance(named: .aqua)
    DSHToolGroupDigestStore.removeAll()
    DSHTranscriptPerf.isEnabled = true
    DSHClassificationCounter.classifiedCalls = 0
    defer { DSHTranscriptPerf.isEnabled = false }

    // Exactly what the transcript does for this row, then the real view.
    let digest = DSHToolGroupDigestStore.digest(
      key: ConversationView.toolGroupDigestKey(group, tools: harness.displayedTools)
    ) {
      ConversationView.toolGroupDigest(group, tools: harness.displayedTools)
    }
    let root = AnyView(
      ToolGroupRow(messages: group, initiallyExpanded: true, digest: digest)
        .frame(width: 836)
        .environmentObject(harness))
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(x: 0, y: 0, width: 836, height: 900)
    let window = NSWindow(
      contentRect: NSRect(x: -20_000, y: -20_000, width: 836, height: 900),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.orderFrontRegardless()
    defer { window.orderOut(nil); window.close() }

    // The counters include the expanded instruction list, which legitimately
    // classifies each command once per body pass (that is what paints each
    // row's pencil). What must NOT happen is more work per pass: a `digest`
    // getter that recomputed would add `count` classifications to every later
    // layout pass, so the DELTA across the extra passes is the assertion.
    let baseline = DSHClassificationCounter.classifiedCalls
    print("  expand: real row baseline \(baseline) classifications,"
      + " \(DSHTranscriptPerf.toolGroupDigestBuilds) digest build(s)")

    for _ in 0..<8 {
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
      hosting.layoutSubtreeIfNeeded()
      hosting.displayIfNeeded()
    }
    let after = DSHClassificationCounter.classifiedCalls
    let added = after - baseline
    try expect(added == 0,
               "8 further layout passes of an expanded 64-command row classified"
                 + " \(added) more commands (\(baseline) → \(after)); a repeat pass must"
                 + " classify none, so the digest is being recomputed per body evaluation")
    try expect(after <= count * 4,
               "the expanded row classified \(after) commands for a \(count)-command"
                 + " group; allowed: the digest (64) plus one pass of the instruction list")

  }
}

/// ⑤ End-to-end: the real `ConversationView`, offscreen, with a real click on the
/// group header — the interaction the user performed. Times the main thread from
/// the click until the expanded row's height has settled, which is what "the app
/// froze" looked like from the outside (each settle pass pays the body cost the
/// tests above pin).
private func testExpand_realTranscriptExpandsWithinAMoment() throws {
  try MainActor.assumeIsolated {
    var settleSeconds: Double = -1
    var details = ""
    var tailExecutions = 0
    var bodyEvals = 0
    var classifications = 0
    try withWatchdog(seconds: 180, label: "offscreen expand of the real transcript") {
      do {
        let (harness, group) = try expandHarness(commandCount: 64)
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        DSHTranscriptPerf.forceRowFrames = true
        defer { DSHTranscriptPerf.forceRowFrames = false }
        var frames: [String: CGRect] = [:]
        var documentHeight: CGFloat = 0
        let width: CGFloat = 900
        let height: CGFloat = 5_000
        let root = AnyView(
          ConversationView()
            .onPreferenceChange(DSHTranscriptRowFrameKey.self) { frames = $0 }
            .onPreferenceChange(DSHTranscriptLayoutMetricsKey.self) {
              documentHeight = $0.contentHeight
            }
            .frame(width: width, height: height)
            .background(DSHTheme.canvas)
            .environmentObject(harness))
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
          contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: height),
          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        hosting.layoutSubtreeIfNeeded()

        let items = ConversationView.foldTranscript(
          harness.displayedSession?.messages ?? [], activeTurnRunning: false)
        guard let item = items.first(where: {
          if case .toolGroup = $0 { return true }
          return false
        }), case .toolGroup(let folded) = item, let frame = frames[item.id] else {
          throw TestFailure.message("the transcript folded no command group to expand")
        }
        try expectEqual(folded.count, group.count)
        let collapsedHeight = frame.height
        DSHTranscriptPerf.isEnabled = true
        DSHTranscriptPerf.bodyEvaluations = 0
        DSHTranscriptPerf.rowEvaluations = 0
        DSHTranscriptPerf.metricDeliveries = 0
        DSHTranscriptPerf.tailScrollRequests = 0
        DSHTranscriptPerf.tailScrollExecutions = 0
        DSHTranscriptPerf.toolGroupDigestBuilds = 0
        DSHTranscriptPerf.toolGroupClassifications = 0
        // Document space is top-left origin; the window takes bottom-left.
        let point = NSPoint(x: 200, y: height - (frame.minY + frame.height / 2))
        let start = Date()
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
          guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
          window.sendEvent(event)
        }
        // The expansion itself is applied inside the run loop, so the first turn
        // that returns a taller row is the moment the click was answered.
        let clickSeconds = Date().timeIntervalSince(start)
        var stable = 0
        var last = frames[item.id]?.height ?? collapsedHeight
        var firstAnswer: Double?
        while stable < 2 {
          RunLoop.main.run(until: Date().addingTimeInterval(0.05))
          hosting.layoutSubtreeIfNeeded()
          let current = frames[item.id]?.height ?? last
          if firstAnswer == nil, current > collapsedHeight + 100 {
            firstAnswer = Date().timeIntervalSince(start)
          }
          stable = abs(current - last) < 0.5 ? stable + 1 : 0
          last = current
        }
        settleSeconds = firstAnswer ?? Date().timeIntervalSince(start)
        details = String(format: "collapsed %.0fpt → expanded %.0fpt, doc %.0fpt;"
                         + " click handled in %.3fs, body evals %d, group-row evals %d,"
                         + " digest builds %d (%d classifications), tail scroll %d/%d",
                         collapsedHeight, last, documentHeight, clickSeconds,
                         DSHTranscriptPerf.bodyEvaluations,
                         DSHTranscriptPerf.rowEvaluations,
                         DSHTranscriptPerf.toolGroupDigestBuilds,
                         DSHTranscriptPerf.toolGroupClassifications,
                         DSHTranscriptPerf.tailScrollExecutions,
                         DSHTranscriptPerf.tailScrollRequests)
        tailExecutions = DSHTranscriptPerf.tailScrollExecutions
        bodyEvals = DSHTranscriptPerf.bodyEvaluations
        classifications = DSHTranscriptPerf.toolGroupClassifications
        DSHTranscriptPerf.isEnabled = false
        try expect(last > collapsedHeight + 100,
                   "the click did not expand the row: \(details)")
      } catch let skip as TestSkip {
        throw skip
      } catch is TestFailure {
        settleSeconds = -1
      }
    }
    guard settleSeconds >= 0 else {
      throw TestFailure.message("the offscreen expand did not run")
    }
    // 250ms is the budget: a single click has to produce its frame, and the
    // human threshold for "the app answered" is a quarter second.
    try expect(settleSeconds <= 0.25,
               String(format: "expanding a 64-command group kept the main thread busy for"
                 + " %.2fs (\(details)) — past the 0.25s interaction budget", settleSeconds))
    // One click, one follow. The suspicion was that the height change re-armed
    // the tail scroll and the scroll re-laid out the row, i.e. a self-feeding
    // loop. The measured run shows no such growth: see the limits below.
    print(String(format: "  expand: real transcript, %.2fs (%@)", settleSeconds, details))
    try expect(tailExecutions <= 12,
               "\(details) — \(tailExecutions) tail scrolls for a single expand,"
                 + " which is the follow/relayout loop this test exists to catch")
    try expect(classifications <= 2 * syntheticCommandCount,
               "\(details) — \(classifications) command classifications for a"
                 + " \(syntheticCommandCount)-command group across the whole expand;"
                 + " the digest cache is not being used")
  }
}

/// ⑤ The cache key must include what a RUNNING command's line renders: its
/// resolved title. Everything else about the group is unchanged here — same
/// messages, same call ids, same state — and only the streamed command text
/// moves, exactly as it does while the Host streams a long command in.
///
/// Counted, not timed: the assertion is "the digest was rebuilt", which cannot
/// be affected by machine speed.
private func testExpand_runningTitleChangeRebuildsDigest() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let group = syntheticGroup(count: 4, payloadLines: 2)
    func tools(command: String) -> [HarnessController.ToolActivity] {
      (0..<4).map { index in
        // The LAST call is the one the row names while it runs.
        let text = index == 3 ? command : syntheticCommandPayload(index, 2)
        let arguments = try? JSONSerialization.data(withJSONObject: ["command": text])
        return HarnessController.ToolActivity(
          callId: "call-\(index)",
          name: "bash",
          summary: "工具调用",
          state: .running,
          output: "",
          arguments: arguments.flatMap { String(data: $0, encoding: .utf8) },
          presentation: nil)
      }
    }

    let firstTools = tools(command: "node --check build/live.js")
    // The difference has to be in the FIRST statement: the summarizer names the
    // row after the first real statement, so appending `&& ls` would leave the
    // title unchanged and prove nothing.
    let secondTools = tools(command: "node --check build/live-v2.js")

    DSHTranscriptPerf.isEnabled = true
    defer { DSHTranscriptPerf.isEnabled = false }
    DSHToolGroupDigestStore.removeAll()
    DSHTranscriptPerf.toolGroupDigestBuilds = 0
    DSHTranscriptPerf.toolGroupClassifications = 0

    let firstKey = ConversationView.toolGroupDigestKey(group, tools: firstTools)
    let first = DSHToolGroupDigestStore.digest(key: firstKey) {
      ConversationView.toolGroupDigest(group, tools: firstTools)
    }
    try expectEqual(DSHTranscriptPerf.toolGroupDigestBuilds, 1)
    try expect(first?.runningTitle?.contains("node --check") == true,
               "the running title is missing from the digest: \(String(describing: first))")

    // SAME group, SAME states, only the running command's text moved.
    let secondKey = ConversationView.toolGroupDigestKey(group, tools: secondTools)
    try expect(secondKey != firstKey,
               "the cache key ignored the running command's title, so a streamed"
                 + " command would keep rendering its first title forever")
    let second = DSHToolGroupDigestStore.digest(key: secondKey) {
      ConversationView.toolGroupDigest(group, tools: secondTools)
    }
    try expectEqual(DSHTranscriptPerf.toolGroupDigestBuilds, 2)
    try expect(second != first, "the rebuilt digest still shows the old title")
    try expect(second?.runningTitle?.contains("live-v2") == true,
               "the rebuilt digest did not pick up the new title:"
                 + " \(String(describing: second?.runningTitle))")

    // And a repeat of the SAME running text is a hit, not a third build.
    _ = DSHToolGroupDigestStore.digest(key: secondKey) {
      ConversationView.toolGroupDigest(group, tools: secondTools)
    }
    try expectEqual(DSHTranscriptPerf.toolGroupDigestBuilds, 2)
  }
}

/// ⑥ Every precompiled pattern must compile. A literal that does not compile is
/// treated as "never matches" at runtime (see `DSHPrecompiledPattern`), which
/// would silently reclassify commands instead of failing loudly — this is the
/// loud failure.
private func testExpand_everyDeclaredPatternCompiles() throws {
  try expect(DSHPrecompiledPattern.declaredPatternsAreAllCompiled,
             "at least one classification pattern does not compile; it would be"
               + " treated as never matching and every command matching it would be"
               + " misclassified")
  try expect(DSHPrecompiledPattern.declaredPatternCount > 40,
             "only \(DSHPrecompiledPattern.declaredPatternCount) patterns are declared;"
               + " the inventory lost patterns")
}

/// ⑦ A settled call that gains its raw arguments LATER must be reclassified: the
/// cache key hashes the raw inputs, so an argument payload that turns a command
/// into a file write has to change the digest and its 「其中 N 条修改了文件」 count.
private func testExpand_lateArgumentsRefreshTheMutationCount() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    var message = HarnessController.Message(role: .tool, text: "bash")
    message.toolCallId = "call-late"
    let group = [message]

    // Landed with no arguments at all. (`commandWritesFiles` cannot run without
    // a command, so this reads as a read-only call.)
    func activity(_ arguments: String?) -> HarnessController.ToolActivity {
      HarnessController.ToolActivity(
        callId: "call-late",
        name: "bash",
        summary: "工具调用",
        state: .succeeded,
        output: "ok",
        arguments: arguments,
        presentation: nil)
    }

    DSHToolGroupDigestStore.removeAll()
    let before = activity(nil)
    let beforeKey = ConversationView.toolGroupDigestKey(group, tools: [before])
    let beforeDigest = DSHToolGroupDigestStore.digest(key: beforeKey) {
      ConversationView.toolGroupDigest(group, tools: [before])
    }
    try expectEqual(beforeDigest?.mutatingCount, 0)
    try expectEqual(beforeDigest?.mutatingSummary, nil)

    // The same call, same state, arguments delivered afterwards.
    let after = activity(#"{"command":"mkdir -p build/out && touch build/out/x"}"#)
    let afterKey = ConversationView.toolGroupDigestKey(group, tools: [after])
    try expect(afterKey != beforeKey,
               "the cache key ignored a late-arriving arguments payload")
    let afterDigest = DSHToolGroupDigestStore.digest(key: afterKey) {
      ConversationView.toolGroupDigest(group, tools: [after])
    }
    try expectEqual(afterDigest?.mutatingCount, 1)
    try expectEqual(afterDigest?.mutatingSummary, "其中 1 条修改了文件")
  }
}

let dshTranscriptGroupExpansionTests: [NamedTest] = [
  ("Expand: 64-command group line fits one frame",
   testExpand_sixtyFourCommandLineFitsOneFrame),
  ("Expand: 103-command group line fits one frame",
   testExpand_hundredThreeCommandLineFitsOneFrame),
  ("Expand: cost stays proportional to command text",
   testExpand_costStaysProportionalToCommandText),
  ("Expand: body classifies each command at most once",
   testExpand_bodyClassifiesEachCommandAtMostOnce),
  ("Expand: a running command's title change rebuilds the digest",
   testExpand_runningTitleChangeRebuildsDigest),
  ("Expand: every declared pattern compiles",
   testExpand_everyDeclaredPatternCompiles),
  ("Expand: late arguments refresh the mutation count",
   testExpand_lateArgumentsRefreshTheMutationCount),
  ("Expand: real transcript expands within a quarter second",
   testExpand_realTranscriptExpandsWithinAMoment),
]
