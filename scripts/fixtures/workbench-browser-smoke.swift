import AppKit
import Foundation
import WebKit
@testable import DSHAppLib

enum WorkbenchBrowserSmokeFailure: Error, CustomStringConvertible {
  case invalid(String)

  var description: String {
    switch self { case .invalid(let message): message }
  }
}

@main
struct WorkbenchBrowserSmoke {
  @MainActor
  static func main() throws {
    guard CommandLine.arguments.count == 2,
          let url = URL(string: CommandLine.arguments[1]) else {
      throw WorkbenchBrowserSmokeFailure.invalid("usage: workbench-browser-smoke URL")
    }
    _ = NSApplication.shared
    let runtime = DSHBrowserRuntime()
    runtime.webView.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
    let window = NSWindow(
      contentRect: runtime.webView.frame,
      styleMask: .borderless,
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = runtime.webView
    window.orderFrontRegardless()
    runtime.navigate(to: url)
    defer {
      runtime.stop()
      window.orderOut(nil)
      window.close()
    }

    let loadDeadline = Date().addingTimeInterval(10)
    while Date() < loadDeadline,
          runtime.title != "DSH Workbench Smoke",
          runtime.errorMessage == nil {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    guard runtime.errorMessage == nil else {
      throw WorkbenchBrowserSmokeFailure.invalid("navigation failed: \(runtime.errorMessage ?? "unknown")")
    }
    guard runtime.title == "DSH Workbench Smoke" else {
      throw WorkbenchBrowserSmokeFailure.invalid("page title did not load")
    }

    var bodyText: String?
    var evaluationError: Error?
    runtime.webView.evaluateJavaScript("document.body.textContent") { result, error in
      bodyText = result as? String
      evaluationError = error
    }
    let scriptDeadline = Date().addingTimeInterval(5)
    while Date() < scriptDeadline, bodyText == nil, evaluationError == nil {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    guard evaluationError == nil, bodyText?.contains("workbench-browser-ok") == true else {
      throw WorkbenchBrowserSmokeFailure.invalid("page body did not load")
    }
    print("workbench-browser-smoke: OK")
  }
}
