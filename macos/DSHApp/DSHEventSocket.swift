import Foundation


/// Native WebSocket receiver for DSH Host event streams. It consumes the same
/// typed server-request envelopes the browser UI consumes, without rendering
/// any browser surface.
final class DSHEventSocket {
  private let task: URLSessionWebSocketTask
  private var stopped = false
  private let handler: ([String: Any]) -> Void
  private let onClosed: (() -> Void)?

  init(baseURL: URL, path: String, handler: @escaping ([String: Any]) -> Void, onClosed: (() -> Void)? = nil) {
    var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    components.scheme = components.scheme == "https" ? "wss" : "ws"
    self.task = URLSession.shared.webSocketTask(with: components.url!)
    self.handler = handler
    self.onClosed = onClosed
  }

  func start() {
    task.resume()
    receive()
  }

  func stop() {
    stopped = true
    task.cancel(with: .goingAway, reason: nil)
  }

  private func receive() {
    task.receive { [weak self] result in
      guard let self, !self.stopped else { return }
      switch result {
      case .success(let message):
        let data: Data?
        switch message {
        case .string(let text): data = text.data(using: .utf8)
        case .data(let bytes): data = bytes
        @unknown default: data = nil
        }
        if let data,
           let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           envelope["type"] as? String == "server-request",
           var payload = envelope["payload"] as? [String: Any] {
          payload["_rpcId"] = envelope["rpcId"]
          DispatchQueue.main.async { self.handler(payload) }
        }
        self.receive()
      case .failure:
        DispatchQueue.main.async { self.onClosed?() }
      }
    }
  }
}