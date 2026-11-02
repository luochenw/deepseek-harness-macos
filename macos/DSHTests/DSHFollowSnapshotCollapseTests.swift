import AppKit
import Foundation
@testable import DSHAppLib

// MARK: - A follow frame must never shrink a complete transcript

/// A follow's first frame carries one message and one turn (Host/AGENTS.md).
/// Before 2026-10-30 that frame was assigned straight over the displayed array,
/// so opening a session that already had its full history collapsed the list to
/// a single row (content height 61347 → 797) and it then grew back page by page.

@MainActor
private func message(_ text: String, role: HarnessController.Message.Role = .assistant) -> HarnessController.Message {
  HarnessController.Message(role: role, text: text)
}

/// ① The reported collapse: 40 displayed rows, then a one-row follow frame.
private func testFollowSnapshot_singleRowFrameKeepsTheTranscript() throws {
  try MainActor.assumeIsolated {
    let displayed = (0..<40).map { message("第 \($0) 段已经显示的内容") }
    let frame = [message("只剩这一条")]
    let applied = DSHHistoryPageMerge.applyFollowSnapshot(
      frame, to: displayed, isComplete: false)
    print("  follow: displayed=\(displayed.count) frame=\(frame.count) applied=\(applied.count)")
    try expect(applied.count >= displayed.count,
               "a \(frame.count)-row follow frame collapsed a \(displayed.count)-row transcript"
                 + " to \(applied.count) rows")
    try expectEqual(applied.prefix(displayed.count).map(\.id), displayed.map(\.id))
  }
}

/// ② A complete snapshot still wins: the Host's settled tail is authoritative.
private func testFollowSnapshot_completeFrameReplaces() throws {
  try MainActor.assumeIsolated {
    let displayed = (0..<5).map { message("旧的第 \($0) 行") }
    let full = (0..<9).map { message("新的第 \($0) 行") }
    let applied = DSHHistoryPageMerge.applyFollowSnapshot(
      full, to: displayed, isComplete: false)
    try expectEqual(applied.count, full.count)
    try expectEqual(applied.map(\.text), full.map(\.text))
  }
}

/// ③ An empty transcript takes the frame as-is (nothing to protect).
private func testFollowSnapshot_emptyTranscriptTakesTheFrame() throws {
  try MainActor.assumeIsolated {
    let frame = [message("第一条")]
    try expectEqual(
      DSHHistoryPageMerge.applyFollowSnapshot(frame, to: [], isComplete: false).count,
      1)
  }
}

/// The whole log wins even when shorter: compaction really removes rows, and
/// merging would keep them on screen.
private func testFollowSnapshot_shorterCompleteLogReplaces() throws {
  try MainActor.assumeIsolated {
    let displayed = (0..<5).map { message("压缩前的第 \($0) 行") }
    let log = [message("压缩后的摘要")]
    let applied = DSHHistoryPageMerge.applyFollowSnapshot(log, to: displayed, isComplete: true)
    try expectEqual(applied.map(\.text), log.map(\.text))
  }
}

/// ④ The no-op tail scroll: an offset already at the tail must not be re-requested.
private func testTailScroll_alreadyAtTailIsSuppressed() throws {
  try expect(!DSHConversationScrollPolicy.shouldIssueTailScroll(realBottomDistance: 0),
             "a viewport parked at the tail must not issue another tail scroll")
  try expect(!DSHConversationScrollPolicy.shouldIssueTailScroll(realBottomDistance: 1.5))
  try expect(DSHConversationScrollPolicy.shouldIssueTailScroll(realBottomDistance: 240),
             "a viewport 240pt above the tail must still follow")
  try expect(DSHConversationScrollPolicy.shouldIssueTailScroll(realBottomDistance: nil),
             "with no measurement available the scroll must still be requested")
}

let dshFollowSnapshotCollapseTests: [NamedTest] = [
  ("A one-row follow frame keeps the displayed transcript",
   testFollowSnapshot_singleRowFrameKeepsTheTranscript),
  ("A complete follow frame still replaces the transcript",
   testFollowSnapshot_completeFrameReplaces),
  ("A shorter complete log replaces the transcript", testFollowSnapshot_shorterCompleteLogReplaces),
  ("An empty transcript takes the follow frame",
   testFollowSnapshot_emptyTranscriptTakesTheFrame),
  ("A tail scroll already at the tail is suppressed",
   testTailScroll_alreadyAtTailIsSuppressed),
]
