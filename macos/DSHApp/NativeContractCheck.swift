import Foundation

/// Compile-time fixtures for native Host contract encoders. `scripts/test-macos-native.sh`
/// typechecks the whole app, so these fixtures fail when the production request models no
/// longer support the wire shapes the native client sends.
struct NativeDSHContractCheck {
  static func queueAction() -> DSHQueueAction { .edit("hello") }

  static func attachment() -> DSHAttachmentRef {
    DSHAttachmentRef(attachmentId: "fixture", mediaType: "image/png", bytes: 1, width: 1, height: 1, name: "fixture.png")
  }

  static func promptEnvelope() -> DSHRPCEnvelope<DSHPromptPayload> {
    DSHRPCEnvelope(
      rpcId: "native-contract-fixture",
      method: "session.prompt",
      payload: DSHPromptPayload(sessionId: "session-fixture", mode: "queue", content: [.text("hello")])
    )
  }

  static func resolvedDeliveredPaths() -> [String] {
    [
      HarnessController.resolveWorkspacePath("reports/result.md", workspace: URL(fileURLWithPath: "/workspace", isDirectory: true)),
      HarnessController.resolveWorkspacePath("/tmp/result.md", workspace: URL(fileURLWithPath: "/workspace", isDirectory: true)),
    ]
  }

  static func settingsEnvelope() -> DSHRPCEnvelope<DSHSettingsUpdatePayload> {
    DSHRPCEnvelope(
      rpcId: "native-contract-fixture",
      method: "settings.update",
      payload: DSHSettingsUpdatePayload(
        ns: "profile",
        patch: DSHJSONPatch(values: ["enabled": true, "retries": 2, "labels": ["one", "two"]]),
        expectedRevision: 1
      )
    )
  }

  static func agentProfileDraft() -> DSHAgentProfileDraft {
    DSHAgentProfileDraft(
      id: nil,
      name: "实现助手",
      mention: "implementer",
      description: "并行实现与审查",
      persona: "保持改动聚焦并给出测试证据。",
      defaultTask: "检查当前改动并运行测试。",
      defaultMode: .execution,
      allowModelDispatch: false,
      integrationPolicy: .manual,
      adapters: [
        DSHAgentAdapterBinding(
          id: "dsh",
          runtime: "dsh",
          enabled: true,
          displayName: "DSH",
          model: nil,
          toolAllowlist: ["read", "grep"],
          toolDenylist: ["bash", "write"],
          analysisSupported: true,
          executionSupported: true,
          config: nil),
      ])
  }

  static func agentBatchStart() -> DSHAgentBatchStartArgs {
    DSHAgentBatchStartArgs(
      profileId: "profile-fixture",
      rootSessionId: "root-fixture",
      initiatorSessionId: "child-fixture",
      task: "检查实现并给出结果",
      mode: .analysis,
      integrationPolicy: .manual,
      source: .composer)
  }
}
