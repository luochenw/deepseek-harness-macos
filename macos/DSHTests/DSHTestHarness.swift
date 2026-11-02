import Foundation
@testable import DSHAppLib

extension HarnessController {
  /// Feeds a hand-written `{sessionId, event, view}` frame to the real entry point.
  func deliverFrame(_ frame: [String: Any]) {
    guard let sessionID = frame["sessionId"] as? String else { return }
    if let jobs = frame["jobs"] as? [[String: Any]] {
      applySessionJobs(sessionID: sessionID, jobs: jobs)
      return
    }
    guard let event = frame["event"] as? [String: Any], let raw = DSHRawEvent(frame: event) else { return }
    consumeSessionEvent(
      raw,
      view: frame["view"].flatMap { DSHProjectionDecoder.decode(DSHJSONValue.self, from: $0) },
      sessionID: sessionID)
  }
}
