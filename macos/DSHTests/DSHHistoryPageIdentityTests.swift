import AppKit
import Foundation
@testable import DSHAppLib

// MARK: - Paging must keep row identity, order and count

/// Fold one page of raw history exactly as the Host path does.
@MainActor
private func foldPage(_ records: [[String: Any]], _ harness: HarnessController) throws -> [HarnessController.Message] {
  let data = try JSONSerialization.data(withJSONObject: ["records": records])
  let decoded = try JSONDecoder().decode([String: [DSHHistoryEntry]].self, from: data)
  return harness.foldHistoryContent(decoded["records"] ?? []).messages
}

private func entry(_ type: String, _ seq: Int, _ data: [String: Any]) -> [String: Any] {
  ["event": ["type": type, "seq": seq, "time": 1_793_158_000_000 + seq * 1_000, "data": data]]
}

private func text(_ value: String) -> [[String: Any]] { [["type": "text", "text": value]] }

/// A 600-event log split into two pages, with the repeats that used to make the
/// merge heuristic compare content: identical user texts, identical tool names.
private func twoPageLog() -> (recent: [[String: Any]], older: [[String: Any]]) {
  var older: [[String: Any]] = []
  var recent: [[String: Any]] = []
  var seq = 1
  func turn(into page: inout [[String: Any]]) {
    let userText = seq % 6 == 1 ? "继续" : "第 \(seq) 轮：请检查这个模块。"
    page.append(entry("user/message", seq, ["id": "u-\(seq)", "role": "user", "content": text(userText)]))
    seq += 1
    page.append(entry("assistant/message", seq, [
      "id": "a-\(seq)", "role": "assistant",
      "content": text((0..<3).map { "第 \(seq) 段回复第 \($0) 行。" }.joined(separator: "\n\n")),
    ]))
    seq += 1
    let callId = "call-\(seq)"
    page.append(entry("tool/call", seq, ["name": "bash", "callId": callId,
      "arguments": #"{"command":"cd p && ls"}"#]))
    seq += 1
    page.append(entry("tool/result", seq, ["callId": callId, "success": true, "result": "ok"]))
    seq += 1
  }
  for _ in 0..<30 { turn(into: &older) }
  for _ in 0..<30 { turn(into: &recent) }
  return (recent, older)
}

/// ① A page arriving above never rewrites a row that is already on screen: the
/// UUID of every message in the visible tail stays put, so `LazyVStack` can keep
/// its rows (and a command group keeps its expansion state).
private func testPagingAppend_preservesVisibleRowIDs() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let (recentRecords, olderRecords) = twoPageLog()
    let recent = try foldPage(recentRecords, harness)
    let older = try foldPage(olderRecords, harness)
    try expect(recent.count > 30, "the recent page must be big enough to compare")

    let prepended = DSHHistoryPageMerge.prepend(older, to: recent)
    // Match by position from the tail: the older page was inserted above, so a
    // visible row at offset i from the end must keep its UUID.
    var rewritten = 0
    for offset in 1...recent.count {
      let before = recent[recent.count - offset]
      let after = prepended[prepended.count - offset]
      if before.id != after.id { rewritten += 1 }
    }
    print("  paging: recent=\(recent.count) older=\(older.count) merged=\(prepended.count) idsRewritten=\(rewritten)")
    try expectEqual(rewritten, 0)
    // And the new page is entirely above the old one, in log order.
    try expectEqual(Array(prepended.suffix(recent.count)).map(\.id), recent.map(\.id))
  }
}

/// ② The follow-snapshot completion path (`replaceVisibleOnCompletion`) rebuilds
/// the list from `replacementSeed` + the older pages. It must not duplicate or
/// reorder rows, even when several user messages share the same text.
private func testPagingReplace_keepsOrderAndCount() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let (recentRecords, olderRecords) = twoPageLog()
    let recent = try foldPage(recentRecords, harness)
    let older = try foldPage(olderRecords, harness)

    // loadAllOlderHistory accumulates older pages onto the seed, then merges the
    // visible tail in at completion.
    let repaired = DSHHistoryPageMerge.prepend(older, to: recent)
    let merged = DSHHistoryPageMerge.mergeTail(recent, into: repaired)
    let expected = older + recent
    print("  replace: seed=\(recent.count) repaired=\(repaired.count) merged=\(merged.count) expected=\(expected.count)")
    try expectEqual(merged.count, expected.count)
    try expectEqual(merged.map(\.text), expected.map(\.text))
    try expect(merged.map(\.id) == repaired.map(\.id),
               "the completion merge replaced rows instead of folding the tail into them")
  }
}

let dshHistoryPageIdentityTests: [NamedTest] = [
  ("Paging keeps the identity of rows already on screen",
   testPagingAppend_preservesVisibleRowIDs),
  ("Paging completion keeps order, count and row identity",
   testPagingReplace_keepsOrderAndCount),
]
