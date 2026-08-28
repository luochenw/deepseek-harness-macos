import Foundation

/// Entry point for `./scripts/test-macos-native.sh --unit`. Each test file
/// lists its own `[NamedTest]`; this just concatenates and runs them. Add a
/// new test file's array here when it's added.
@main
struct DSHTestsMain {
  static func main() {
    let allTests = dshVoiceTests + dshWorkspaceTests + dshHostProtocolTests + dshAgentPlatformTests + dshAttachmentTests + dshToolPresentationTests + dshToolResultTests + dshSubagentProjectionTests + dshProjectionsTests + dshPermissionAndSubmissionTests
    let ok = runAll(allTests)
    exit(ok ? 0 : 1)
  }
}
