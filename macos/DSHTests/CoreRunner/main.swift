import Foundation
@testable import DSHAppLib

/// Entry point for `./scripts/test-core.sh`: the tests that need only the Core layer.
@main
struct DSHCoreTestsMain {
  static func main() {
    exit(runAll(dshCoreTimelineTests) ? 0 : 1)
  }
}
