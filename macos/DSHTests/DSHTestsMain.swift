import Foundation

/// Entry point for `./scripts/test-macos-native.sh --unit`. Each test file
/// lists its own `[NamedTest]`; this just concatenates and runs them. Add a
/// new test file's array here when it's added.
@main
struct DSHTestsMain {
  static func main() {
    // Built in chunks: one long array concatenation makes the type checker
    // give up ("unable to type-check in reasonable time").
    var allTests: [NamedTest] = []
    allTests += dshVoiceTests
    allTests += dshExceptionDiagnosticsTests
    allTests += dshWorkspaceTests
    allTests += dshWorkbenchTests
    allTests += dshConversationHistoryTests
    allTests += dshConversationScrollStabilityTests
    allTests += dshTaskEscapeTests
    allTests += dshHostProtocolTests
    allTests += dshSidebarTests
    allTests += dshAgentPlatformTests
    allTests += dshAssistantStreamTests
    allTests += dshAttachmentTests
    allTests += dshToolPresentationTests
    allTests += dshToolResultTests
    allTests += dshRunCodeDetailsTests
    allTests += dshSubagentProjectionTests
    allTests += dshProjectionsTests
    allTests += dshPermissionAndSubmissionTests
    allTests += dshMenuBarTests
    allTests += dshExternalAgentBridgeTests()
    allTests += dshToolCallPresentationTests
    allTests += dshTranscriptRowHeightTests
    allTests += dshTranscriptGoldenTests
    allTests += dshTranscriptGroupExpansionTests
    allTests += dshMarkdownLayoutCountTests
    let ok = runAll(allTests)
    exit(ok ? 0 : 1)
  }
}
