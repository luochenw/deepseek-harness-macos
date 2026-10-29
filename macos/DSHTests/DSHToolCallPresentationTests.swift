import AppKit
import Foundation
import SwiftUI
@testable import DSHAppLib

/// Raw `tool/call.data.arguments` strings copied verbatim from a real drawing
/// session (turn 6), so every title/classification assertion below runs against
/// the exact payloads the App receives instead of a hand-written example.
private enum Fixture {
  /// `tool/call` #2 — `cd … && python3 - <<'PY'` with no write.
  static let pythonReadOnly = #"{"command":"cd /Users/developer/Desktop/project/ds-harness/outputs/tomato-tour && python3 - <<'PY'\nimport json\nd=json.load(open('/tmp/ph.json'))\n# look for sunny rural/field skies\nfor k,v in d.items():\n    cats=' '.join(v.get('categories',[])).lower()\n    if 'sun' in cats:\n        print(k, v['name'])\nPY","description":"Find sunny field HDRI candidates","timeoutMs":30000}"#

  /// `tool/call` #17 — python heredoc that rewrites `js/scene.js`.
  static let pythonWrite = #"{"command":"cd /Users/developer/Desktop/project/ds-harness/outputs/tomato-tour && python3 - <<'PY'\np='js/scene.js'\ns=open(p).read()\nold=\"const asphalt = 1;\"\nnew=\"const asphalt = 2;\"\nassert old in s\ns=s.replace(old,new)\nopen(p,'w').write(s)\nprint('ok')\nPY\nnode --check js/scene.js; echo check=$?","description":"Swap road and ground to PBR","timeoutMs":20000}"#

  /// `tool/call` #32 — `cat > X <<'EOF'`.
  static let catHeredoc = #"{"command":"cd /Users/developer/Desktop/project/ds-harness/outputs/tomato-tour && cat > /tmp/probe.js <<'EOF'\nconst { spawn } = require('child_process');\nconsole.log('probe');\nEOF","description":"Write a probe script","timeoutMs":20000}"#

  /// `tool/call` #33 — download + unpack, one line, `&&` chain.
  static let curlTar = #"{"command":"cd /tmp && curl -sL --max-time 120 -o three.tgz \"https://registry.npmjs.org/three/-/three-0.169.0.tgz\" -w \"%{http_code} %{size_download}\\n\" && mkdir -p t3pkg && tar -xzf three.tgz -C t3pkg && ls t3pkg/package/examples/jsm | head","description":"Download three npm tarball for addons","timeoutMs":180000}"#

  /// `tool/call` #34 — `rm`/`cp` chain.
  static let removeCopy = #"{"command":"cd /Users/developer/Desktop/project/ds-harness/outputs/tomato-tour && rm -rf vendor/three && mkdir -p vendor/three && cp /tmp/t3pkg/package/build/three.module.js vendor/three/ && du -sh vendor/three","description":"Vendor full three r169","timeoutMs":60000}"#

  /// `tool/call` #16 — grep, read-only.
  static let grepRead = #"{"command":"cd /Users/developer/Desktop/project/ds-harness/outputs/tomato-tour && grep -n \"const asphalt = \\|const verge = \" js/scene.js","description":"Locate materials","timeoutMs":20000}"#

  /// `tool/call` #9 — write.
  static let write = #"{"content":"<!doctype html>\n<html lang=\"zh-CN\">\n<head>\n<title>番茄骑行</title>","file_path":"/Users/developer/Desktop/project/ds-harness/outputs/tomato-tour/index.html"}"#

  /// `tool/call` #10 — read.
  static let read = #"{"file_path":"/Users/developer/Desktop/project/ds-harness/outputs/tomato-tour/js/scene.js","limit":52,"offset":14}"#

  /// `tool/call` #40 — read_image.
  static let readImage = #"{"file_path":"/tmp/s1.jpg"}"#

  /// `tool/call` #1 — probe line with `curl -o` in the middle of an `&&` chain.
  static let curlProbe = #"{"command":"cd /Users/developer/Desktop/project/ds-harness/outputs/tomato-tour && echo \"--- polyhaven\" && curl -s --max-time 15 \"https://api.polyhaven.com/assets?t=hdris&c=skies\" -o /tmp/ph.json -w \"%{http_code}\\n\" && head -c 200 /tmp/ph.json","description":"Probe asset sources reachability","timeoutMs":60000}"#

  static func activity(
    name: String,
    arguments: String,
    callId: String,
    state: HarnessController.ToolActivity.State = .succeeded
  ) -> HarnessController.ToolActivity {
    HarnessController.ToolActivity(
      callId: callId,
      name: name,
      summary: state == .running ? "正在运行" : "工具调用",
      state: state,
      output: "",
      arguments: arguments,
      presentation: HarnessController.ToolPresentation.fromToolCall(
        name: name,
        arguments: arguments))
  }

  /// The ten representative calls above, in the order they appear in the run.
  static var activities: [HarnessController.ToolActivity] {
    [
      activity(name: "bash", arguments: pythonReadOnly, callId: "f2"),
      activity(name: "bash", arguments: pythonWrite, callId: "f17"),
      activity(name: "bash", arguments: catHeredoc, callId: "f32"),
      activity(name: "bash", arguments: curlTar, callId: "f33"),
      activity(name: "bash", arguments: removeCopy, callId: "f34"),
      activity(name: "bash", arguments: grepRead, callId: "f16"),
      activity(name: "write", arguments: write, callId: "f9"),
      activity(name: "read", arguments: read, callId: "f10"),
      activity(name: "read_image", arguments: readImage, callId: "f40"),
      activity(name: "bash", arguments: curlProbe, callId: "f1"),
    ]
  }
}

// MARK: - Titles

private func testToolTitles_neverBlankForEveryFixtureCall() throws {
  for tool in Fixture.activities {
    let title = DSHToolGroupStatus.instructionTitle(for: tool)
    try expect(
      title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
      "\(tool.name) produced a blank title")
    let instructions = DSHToolInstructionFlatten.instructions(from: [tool])
    try expectEqual(instructions.count, 1)
    try expect(
      instructions.first?.title.trimmingCharacters(in: .whitespaces).isEmpty == false,
      "\(tool.name) produced a blank flattened instruction")
  }
}

private func testToolTitles_nameTheRealSubject() throws {
  let byID = Dictionary(
    uniqueKeysWithValues: Fixture.activities.map { ($0.callId, $0) })

  // A python heredoc that writes a file names the file, not the cd prefix.
  try expectEqual(
    DSHToolGroupStatus.instructionTitle(for: byID["f17"]!),
    "Python 脚本 · 修改 js/scene.js")
  // A heredoc that only reads is not reported as a modification.
  try expectEqual(
    DSHToolGroupStatus.instructionTitle(for: byID["f2"]!),
    "Python 脚本 · d=json.load(open('/tmp/ph.json'))")
  // `cat > X <<'EOF'` reads as "写入 X".
  try expectEqual(DSHToolGroupStatus.instructionTitle(for: byID["f32"]!), "写入 /tmp/probe.js")
  // The `cd … && echo "--- label"` preamble is dropped for the real command.
  try expectEqual(
    DSHToolGroupStatus.instructionTitle(for: byID["f1"]!),
    #"curl -s --max-time 15 "https://api.polyhaven.com/assets?t=hdris&c=skies" -o /tmp/ph.json -w "%{http_code}\n""#)
  // File tools keep the path they were given.
  try expectEqual(
    DSHToolGroupStatus.instructionTitle(for: byID["f10"]!),
    "/Users/developer/Desktop/project/ds-harness/outputs/tomato-tour/js/scene.js")
}

private func testToolTitles_carryTheStrippedDirectory() throws {
  let summary = DSHCommandTitle.summarize(
    #"cd /Users/developer/Desktop/project/ds-harness/outputs/tomato-tour && grep -n "x" js/scene.js"#)
  try expectEqual(
    summary.directory,
    "/Users/developer/Desktop/project/ds-harness/outputs/tomato-tour")
  try expectEqual(summary.title, #"grep -n "x" js/scene.js"#)
}

private func testToolTitles_useJobCopy() throws {
  for name in ["job_output", "job_kill"] {
    let tool = Fixture.activity(name: name, arguments: #"{"job_id":"bash-1"}"#, callId: name)
    let title = DSHToolGroupStatus.instructionTitle(for: tool)
    try expect(title?.isEmpty == false, "\(name) produced a blank title")
  }
  try expectEqual(
    DSHJobToolCopy.title(for: "job_output"),
    "等待后台任务输出")
  try expectEqual(DSHJobToolCopy.title(for: "job_kill"), "停止后台任务")
}

private func testToolTitles_neverBlankWithoutArguments() throws {
  let tool = HarnessController.ToolActivity(
    callId: "empty",
    name: "bash",
    summary: "工具调用",
    state: .succeeded,
    output: "",
    arguments: nil,
    presentation: nil)
  try expectEqual(DSHToolGroupStatus.instructionTitle(for: tool), "运行命令")
}

// MARK: - Classification

private func testClassification_marksWritersAndReaders() throws {
  func kind(_ name: String, _ arguments: String) -> DSHToolCallKind {
    DSHToolCallClassifier.kind(name: name, arguments: arguments)
  }

  // Positive: these change files.
  try expectEqual(kind("write", Fixture.write), .mutating)
  try expectEqual(
    kind("edit", #"{"file_path":"a.js","new_string":"x"}"#),
    .mutating)
  try expectEqual(kind("apply_patch", #"{"patch":"*** Begin Patch"}"#), .mutating)
  try expectEqual(kind("bash", #"{"command":"echo hi > out.txt"}"#), .mutating)
  try expectEqual(kind("bash", #"{"command":"echo hi >> out.txt"}"#), .mutating)
  try expectEqual(kind("bash", #"{"command":"printf x | tee out.txt"}"#), .mutating)
  try expectEqual(kind("bash", #"{"command":"sed -i '' 's/a/b/' a.js"}"#), .mutating)
  try expectEqual(kind("bash", #"{"command":"mv a b"}"#), .mutating)
  try expectEqual(kind("bash", #"{"command":"rm -rf vendor"}"#), .mutating)
  try expectEqual(kind("bash", #"{"command":"cp a b && mkdir -p c"}"#), .mutating)
  try expectEqual(kind("bash", #"{"command":"touch a && chmod +x a"}"#), .mutating)
  try expectEqual(kind("bash", #"{"command":"git checkout -- a.js"}"#), .mutating)
  try expectEqual(kind("bash", #"{"command":"pnpm install"}"#), .mutating)
  try expectEqual(kind("bash", #"{"command":"unzip a.zip"}"#), .mutating)
  // Fixture-backed positives.
  try expectEqual(kind("bash", Fixture.pythonWrite), .mutating)
  try expectEqual(kind("bash", Fixture.catHeredoc), .mutating)
  try expectEqual(kind("bash", Fixture.removeCopy), .mutating)
  try expectEqual(kind("bash", Fixture.curlTar), .mutating)

  // Negative: read-only.
  try expectEqual(kind("read", Fixture.read), .readOnly)
  try expectEqual(kind("read_image", Fixture.readImage), .readOnly)
  try expectEqual(kind("grep", #"{"pattern":"x","path":"a.js"}"#), .readOnly)
  try expectEqual(kind("glob", #"{"pattern":"**/*.js"}"#), .readOnly)
  try expectEqual(kind("bash", #"{"command":"ls -la"}"#), .readOnly)
  try expectEqual(kind("bash", #"{"command":"node --check js/scene.js"}"#), .readOnly)
  try expectEqual(kind("bash", #"{"command":"curl -s https://example.com"}"#), .readOnly)
  // Redirections that are plumbing, not file writes.
  try expectEqual(kind("bash", #"{"command":"node a.js 2>&1"}"#), .readOnly)
  try expectEqual(kind("bash", #"{"command":"curl -s https://x/dev/null"}"#), .readOnly)
  try expectEqual(kind("bash", #"{"command":"git status"}"#), .readOnly)
  try expectEqual(kind("bash", #"{"command":"npm run build"}"#), .readOnly)
  // Fixture-backed negatives.
  try expectEqual(kind("bash", Fixture.pythonReadOnly), .readOnly)
  try expectEqual(kind("bash", Fixture.grepRead), .readOnly)
}

// MARK: - Grouping

private func toolMessage(_ name: String, _ callId: String) -> HarnessController.Message {
  HarnessController.Message(role: .tool, text: name, toolCallId: callId)
}

private func testFold_mergesCommandCallsAcrossReasoningAndNarration() throws {
  let messages: [HarnessController.Message] = [
    HarnessController.Message(role: .user, text: "继续"),
    withReasoning(HarnessController.Message(role: .assistant, text: "先看看素材")),
    toolMessage("bash", "c1"),
    withReasoning(HarnessController.Message(role: .assistant, text: "写脚本")),
    toolMessage("bash", "c2"),
    HarnessController.Message(role: .assistant, text: "现在渲染"),
    toolMessage("read", "c3"),
    toolMessage("edit", "c4"),
    // A subagent dispatch must not be folded into the command group.
    toolMessage("run_code", "c5"),
    toolMessage("bash", "c6"),
  ]

  let items = ConversationView.foldTranscript(messages)
  let groups = items.compactMap { item -> [HarnessController.Message]? in
    guard case .toolGroup(let group) = item else { return nil }
    return group
  }
  // bash, bash, read, edit fold into one group; the lone bash after the
  // run_code row stays a plain row (a single command is not a group).
  try expectEqual(groups.count, 1)
  try expectEqual(groups[0].map(\.toolCallId), ["c1", "c2", "c3", "c4"])
  let singles = items.compactMap { item -> String? in
    guard case .message(let message) = item else { return nil }
    return message.toolCallId
  }
  try expect(singles.contains("c5"), "the run_code dispatch must stay its own row")
  try expect(singles.contains("c6"), "a lone command must not become a group")
  // One aggregated trace per turn, and the narration rows survive.
  let traces = items.filter { item in
    if case .reasoning = item { return true }
    return false
  }
  try expectEqual(traces.count, 1)
}

private func testFold_digestCountsCommandsAndMutatingOnes() throws {
  let tools = Fixture.activities
  let messages = tools.map { toolMessage($0.name, $0.callId) }

  let items = ConversationView.foldTranscript(messages)
  guard items.count == 1, case .toolGroup(let group) = items[0] else {
    throw TestFailure.message("one turn of command calls must fold into one group")
  }
  try expectEqual(group.count, tools.count)

  let calls = group.compactMap { message -> DSHToolGroupDigestBuilder.Call? in
    guard let id = message.toolCallId,
          let tool = tools.last(where: { $0.callId == id }),
          let title = DSHToolGroupStatus.instructionTitle(for: tool) else { return nil }
    return DSHToolGroupDigestBuilder.Call(
      title: title,
      kind: tool.callKind,
      running: tool.state == .running)
  }
  let digest = DSHToolGroupDigestBuilder.digest(for: calls)
  try expectEqual(digest?.commandCount, tools.count)
  // f2/f16/f10/f40 only read; the other six change files.
  try expectEqual(digest?.mutatingCount, 6)
  try expectEqual(digest?.headline, "执行了 10 条命令")
  try expectEqual(digest?.mutatingSummary, "其中 6 条修改了文件")
  try expectEqual(digest?.isRunning, false)
  try expectEqual(
    DSHToolGroupDigestBuilder.digest(for: [
      .init(title: "a", kind: .readOnly, running: false),
      .init(title: "b", kind: .readOnly, running: true),
    ])?.headline,
    "执行了 2 条命令")
  try expect(
    DSHToolGroupDigestBuilder.digest(for: [
      .init(title: "a", kind: .readOnly, running: false),
    ])?.mutatingSummary == nil)
}

private func testFold_keepsSingleCommandUngrouped() throws {
  let single = ConversationView.foldTranscript([toolMessage("bash", "only")])
  try expectEqual(single.count, 1)
  guard case .message(let message) = single[0] else {
    throw TestFailure.message("a single command must stay a plain row, not a group")
  }
  try expectEqual(message.toolCallId, "only")

  // Two calls in the same turn do group.
  let pair = ConversationView.foldTranscript([
    toolMessage("read", "r1"),
    toolMessage("grep", "g1"),
  ])
  guard case .toolGroup(let group) = pair[0] else {
    throw TestFailure.message("two commands must group")
  }
  try expectEqual(group.count, 2)
  try expect(!ConversationView.TranscriptItem.shouldGroup([toolMessage("bash", "x")]))
}

private func withReasoning(_ message: HarnessController.Message) -> HarnessController.Message {
  var copy = message
  copy.reasoning = "思考"
  return copy
}

// MARK: - Contrast

/// WCAG contrast for every text role the tool rows use, computed from the
/// `DSHTheme` colours actually rendered (not from a copy of the palette).
private func testContrast_titleAndChipClearFourPointFive() throws {
  for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    guard let ink = DSHContrast.rgba(DSHTheme.ink, appearance: appearance),
          let inkSoft = DSHContrast.rgba(DSHTheme.inkSoft, appearance: appearance),
          let accent = DSHContrast.rgba(DSHTheme.accent, appearance: appearance),
          let rowFill = DSHContrast.rgba(DSHTheme.surfaceTint, appearance: appearance),
          let rowFillHovered = DSHContrast.rgba(DSHTheme.surfaceTint2, appearance: appearance)
    else {
      throw TestFailure.message("\(appearance.rawValue): theme colours did not resolve")
    }
    // Accent chips sit on accentSoft = accent at 11% over the row fill.
    let chipFill = DSHContrast.blend(accent, alpha: 0.11, over: rowFill)
    for background in [rowFill, rowFillHovered] {
      let title = DSHContrast.ratio(ink, background)
      let secondary = DSHContrast.ratio(inkSoft, background)
      try expect(
        title >= 4.5,
        "\(appearance.rawValue): title contrast \(title) < 4.5")
      try expect(
        secondary >= 4.5,
        "\(appearance.rawValue): secondary contrast \(secondary) < 4.5")
    }
    let chip = DSHContrast.ratio(ink, chipFill)
    try expect(chip >= 4.5, "\(appearance.rawValue): chip contrast \(chip) < 4.5")
    print(String(
      format: "%@ contrast — title %.2f:1, secondary %.2f:1, chip %.2f:1",
      appearance.rawValue, DSHContrast.ratio(ink, rowFill),
      DSHContrast.ratio(inkSoft, rowFill), chip))
  }
}

// MARK: - Snapshot

private func testSnapshot_rendersFixtureTranscriptWithoutBlankRows() throws {
  try MainActor.assumeIsolated {
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("dsh-tool-group-snapshots", isDirectory: true)
    try? FileManager.default.removeItem(at: output)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    let tools = Fixture.activities
    _ = NSApplication.shared
    let harness = HarnessController(startRuntime: false)
    harness.activeTools = tools
    let messages = tools.map { toolMessage($0.name, $0.callId) }
    let items = ConversationView.foldTranscript(messages)
    guard items.count == 1, case .toolGroup(let group) = items[0] else {
      throw TestFailure.message("the fixture turn must fold into one command group")
    }

    for (suffix, appearance) in [
      ("", NSAppearance.Name.aqua),
      ("-dark", NSAppearance.Name.darkAqua),
    ] {
      NSApp.appearance = NSAppearance(named: appearance)
      try renderSnapshot(
        items: items,
        harness: harness,
        size: CGSize(width: 1_060, height: 360),
        name: "tool-group-collapsed\(suffix)",
        output: output,
        expandGroups: false,
        appearance: appearance)
      try renderSnapshot(
        items: items,
        harness: harness,
        size: CGSize(width: 1_060, height: 780),
        name: "tool-group-expanded\(suffix)",
        output: output,
        expandGroups: true,
        appearance: appearance)
    }
    NSApp.appearance = NSAppearance(named: .aqua)
    print("tool-group snapshot dir: \(output.path)")
    print("tool-group expanded group N=\(group.count)")
  }
}

@MainActor
private func renderSnapshot(
  items: [ConversationView.TranscriptItem],
  harness: HarnessController,
  size: CGSize,
  name: String,
  output: URL,
  expandGroups: Bool,
  appearance: NSAppearance.Name
) throws {
  let root = AnyView(
    VStack(alignment: .leading, spacing: DSHSpace.s4) {
      ForEach(items) { item in
        if case .toolGroup(let group) = item {
          ToolGroupRow(
            messages: group,
            initiallyExpanded: expandGroups,
            digest: ConversationView.toolGroupDigest(
              group, tools: harness.displayedTools))
        }
      }
    }
    .padding(DSHSpace.s6)
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    .background(DSHTheme.canvas)
    .environmentObject(harness))
  let hosting = NSHostingView(rootView: root)
  hosting.appearance = NSAppearance(named: appearance)
  hosting.frame = NSRect(origin: .zero, size: size)
  let window = NSWindow(
    contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
    styleMask: .borderless,
    backing: .buffered,
    defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = hosting
  window.orderFrontRegardless()
  RunLoop.main.run(until: Date().addingTimeInterval(0.2))
  hosting.layoutSubtreeIfNeeded()
  hosting.displayIfNeeded()
  guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
    window.close()
    throw TestFailure.message("\(name): no bitmap")
  }
  hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
  window.orderOut(nil)
  window.close()
  guard let png = bitmap.representation(using: .png, properties: [:]) else {
    throw TestFailure.message("\(name): cannot encode PNG")
  }
  try expect(png.count > 3_000, "\(name): snapshot looks empty")
  let destination = output.appendingPathComponent("\(name).png")
  try png.write(to: destination)
  print("\(name): \(destination.path)")
}

let dshToolCallPresentationTests: [NamedTest] = [
  ("Tool titles are never blank for any fixture call", testToolTitles_neverBlankForEveryFixtureCall),
  ("Tool titles name the real subject", testToolTitles_nameTheRealSubject),
  ("Tool titles carry the stripped cd directory", testToolTitles_carryTheStrippedDirectory),
  ("Job tools use friendly titles", testToolTitles_useJobCopy),
  ("Missing arguments still produce a title", testToolTitles_neverBlankWithoutArguments),
  ("Classification marks writers and readers", testClassification_marksWritersAndReaders),
  ("Fold merges command calls across reasoning and narration", testFold_mergesCommandCallsAcrossReasoningAndNarration),
  ("Fold digest counts commands and mutating ones", testFold_digestCountsCommandsAndMutatingOnes),
  ("Fold keeps a single command ungrouped", testFold_keepsSingleCommandUngrouped),
  ("Tool row text clears 4.5:1 contrast", testContrast_titleAndChipClearFourPointFive),
  ("Snapshot renders the fixture transcript", testSnapshot_rendersFixtureTranscriptWithoutBlankRows),
]
