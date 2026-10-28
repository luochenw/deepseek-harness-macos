import Foundation
@testable import DSHAppLib

private func testHostReconnectPolicy_isBoundedAndBacksOff() throws {
  try expectEqual(DSHHostReconnectPolicy.maximumAttempts, 5)
  try expectEqual(DSHHostReconnectPolicy.delayNanoseconds(attempt: 1), 750_000_000)
  try expectEqual(DSHHostReconnectPolicy.delayNanoseconds(attempt: 5), 3_750_000_000)
  try expectEqual(DSHHostReconnectPolicy.delayNanoseconds(attempt: 0), 750_000_000)
}

private func testSidebarHostStatus_hidesRoutineSuccessStates() throws {
  try expect(DSHSidebarHostStatus.visible("Host 已同步 37 个会话 / 1 个工作区") == nil)
  try expect(DSHSidebarHostStatus.visible("Host 事件流已重新连接") == nil)
  try expect(DSHSidebarHostStatus.visible("Host 事件流已就绪") == nil)
  try expect(DSHSidebarHostStatus.visible("工作区事件流已结束") == nil)
  try expect(DSHSidebarHostStatus.visible("Host 消息流已断开，正在自动重连") == nil)
  try expect(DSHSidebarHostStatus.visible("Host 事件流已重新连接") == nil)
  try expect(DSHSidebarHostStatus.visible("正在启动持久 DSH Host…") == nil)
  try expectEqual(
    DSHSidebarHostStatus.visible("Host 自动重连失败，请手动重新连接"),
    "Host 自动重连失败，请手动重新连接")
  try expectEqual(
    DSHSidebarHostStatus.visible("会话历史加载失败：timeout"),
    "会话历史加载失败：timeout")
}

private func testAssistantStreamFrame_decodesLiveChunkAndSnapshotBuffer() throws {
  let live = DSHProjectionDecoder.decode(
    DSHSessionAssistantStreamEnvelope.self,
    from: [
      "type": "assistant-stream",
      "frame": [
        "type": "chunk",
        "attemptId": "attempt-1",
        "revision": 2,
        "index": 0,
        "time": 1234,
        "chunk": ["type": "text-delta", "text": "streamed"],
      ],
    ])
  try expectEqual(live?.frame["type"]?.string, "chunk")
  try expectEqual(live?.frame["attemptId"]?.string, "attempt-1")
  try expectEqual(live?.frame["chunk"]?.object?["text"]?.string, "streamed")
  try expectEqual(live?.frame["revision"]?.integer, 2)
  try expectEqual(live?.frame["index"]?.integer, 0)

  let snapshot = DSHSessionFollowSnapshotDecoder.decode([
    "type": "snapshot",
    "header": ["id": "session-1"],
    "cursor": 3,
    "records": [],
    "hasMore": false,
    "projections": [
      "kind": "sequenced",
      "asOfSeq": 3,
      "values": ["title": "streaming"],
    ],
    "assistantStream": [
      "revision": 2,
      "activeAttempt": [
        "attemptId": "attempt-1",
        "nextIndex": 1,
        "stream": [[
          "time": 1234,
          "chunk": ["type": "text-delta", "text": "streamed"],
        ]],
      ],
    ],
  ])
  try expectEqual(snapshot?.assistantStream?.activeAttempt?.stream?.count, 1)
  try expectEqual(
    snapshot?.assistantStream?.activeAttempt?.stream?.first?.chunk.object?["text"]?.string,
    "streamed")
}

private func testFollowSnapshotDecoder_preservesRecordsWhenAuxiliaryDataIsInvalid() throws {
  let frame: [String: Any] = [
    "type": "snapshot",
    "header": ["id": "session-1"],
    "cursor": 2,
    "records": [
      [
        "event": [
          "type": "user/message",
          "seq": 1,
          "time": 1000,
          "data": [
            "message": [
              "role": "user",
              "content": [["type": "text", "text": "survives"]],
            ],
          ],
        ],
      ],
      ["event": ["type": "broken"]],
    ],
    "hasMore": false,
    "projections": [
      "kind": "sequenced",
      "asOfSeq": 2,
      "values": ["title": 42],
    ],
    "assistantStream": ["revision": "broken"],
  ]

  let snapshot = DSHSessionFollowSnapshotDecoder.decode(frame)

  try expectEqual(snapshot?.header.id, "session-1")
  try expectEqual(snapshot?.records.count, 1)
  try expectEqual(snapshot?.records.first?.event.seq, 1)
  try expect(snapshot?.projections == nil)
  try expect(snapshot?.assistantStream == nil)
}

private func testJSONPatchValue_initFailsForUnsupportedType() throws {
  // Date isn't one of the bridged cases (Bool/NSNumber/String/[String:Any]/
  // [Any]/NSNull) DSHJSONPatchValue.init? knows how to wrap.
  try expect(DSHJSONPatchValue(Date()) == nil, "unsupported type should fail to construct, not silently coerce")
}

private func testJSONPatchValue_initWrapsPrimitivesAndNull() throws {
  guard case .bool(true)? = DSHJSONPatchValue(true) else { throw TestFailure.message("expected .bool(true)") }
  guard case .string("hi")? = DSHJSONPatchValue("hi") else { throw TestFailure.message("expected .string(\"hi\")") }
  guard case .null? = DSHJSONPatchValue(NSNull()) else { throw TestFailure.message("expected .null") }
  guard case .number(let n)? = DSHJSONPatchValue(42), n == 42.0 else { throw TestFailure.message("expected .number(42.0)") }
}

private func testJSONPatch_encodesNestedStructureAsRealJSON() throws {
  // This hand-rolled recursive encoder is exactly what a settings.update RPC
  // payload rides on — a silent miscoding here corrupts a settings write.
  let patch = DSHJSONPatch(values: [
    "name": "dsh",
    "count": 3,
    "enabled": true,
    "nested": ["inner": "value"],
    "list": [1, 2, 3],
  ])
  let data = try JSONEncoder().encode(patch)
  let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  try expect(decoded?["name"] as? String == "dsh")
  try expect((decoded?["count"] as? NSNumber)?.doubleValue == 3.0)
  try expect(decoded?["enabled"] as? Bool == true)
  let nested = decoded?["nested"] as? [String: Any]
  try expect(nested?["inner"] as? String == "value")
  let list = decoded?["list"] as? [Any]
  try expectEqual(list?.count, 3)
}

private func testRPCEnvelope_encodesExpectedShape() throws {
  struct Payload: Encodable { let foo: String }
  let envelope = DSHRPCEnvelope(rpcId: "abc", method: "test.method", payload: Payload(foo: "bar"))
  let data = try JSONEncoder().encode(envelope)
  let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  try expect(decoded?["type"] as? String == "client-request")
  try expect(decoded?["rpcId"] as? String == "abc")
  try expect(decoded?["method"] as? String == "test.method")
  let payload = decoded?["payload"] as? [String: Any]
  try expect(payload?["foo"] as? String == "bar")
}

private func testRPCServerResponse_decodesOkResult() throws {
  struct Value: Decodable { let cwd: String }
  let json = Data("""
  {"type":"server-response","rpcId":"abc","result":{"ok":true,"value":{"cwd":"/tmp"}}}
  """.utf8)
  let response = try JSONDecoder().decode(DSHRPCServerResponse<Value>.self, from: json)
  try expect(response.result.ok)
  try expect(response.result.value?.cwd == "/tmp")
}

private func testHostDescription_decodesBundledRuntimeShape() throws {
  let description = try JSONDecoder().decode(DSHHostDescription.self, from: Data("""
  {"version":"0.2.1-rc.2","cwd":"/tmp/project","attachedSessions":2,"home":"/Users/developer","canOpenPath":true}
  """.utf8))
  try expectEqual(description.version, "0.2.1-rc.2")
  try expect(description.provider == nil)
  try expect(description.model == nil)
  try expectEqual(description.home, "/Users/developer")
}

private func testCreateSessionPayload_omitsNilWorkspace() throws {
  let data = try JSONEncoder().encode(DSHCreateSessionPayload(cwd: nil, agentPreset: nil))
  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  try expect(payload?.isEmpty == true)
}

private func testHostLaunchArguments_alwaysSuppressWebUI() throws {
  let arguments = DSHHostRuntime.launchArguments(dshPath: "/tmp/dsh/lib/bin.js")
  try expect(arguments.contains("--no-open"))
}

private func testSessionFollowOpening_requestsMinimalTail() throws {
  try expectEqual(DSHSessionFollowOpeningPolicy.maxMessages, 1)
  try expectEqual(DSHSessionFollowOpeningPolicy.minMessages, 1)
  try expectEqual(DSHSessionFollowOpeningPolicy.minTurns, 1)
  let payload = DSHSessionFollowOpeningPolicy.payload(
    address: ["kind": "session", "sessionId": "session-fixture"])
  let args = payload["args"] as? [String: Any]
  let request = args?["request"] as? [String: Any]
  let turnWindow = request?["turnWindow"] as? [String: Any]
  try expectEqual(request?["maxMessages"] as? Int, 1)
  try expectEqual(turnWindow?["minMessages"] as? Int, 1)
  try expectEqual(turnWindow?["minTurns"] as? Int, 1)
  try expectEqual(request?["assistantStream"] as? Bool, true)
}

private func testHostLaunch_parsesBootstrapTokenAndCookie() throws {
  guard let launch = DSHHostLaunch.parse(
    launchLine: "dsh web: http://127.0.0.1:54321/?token=bootstrap-token")
  else { throw TestFailure.message("expected launch line to parse") }
  try expectEqual(launch.baseURL.absoluteString, "http://127.0.0.1:54321")
  try expectEqual(launch.token, "bootstrap-token")
  guard let cookie = DSHHostAuthCookie.parse(
    setCookie: "dsh-auth-fixture=v1.payload.signature; Max-Age=10; HttpOnly")
  else { throw TestFailure.message("expected auth cookie to parse") }
  try expectEqual(cookie.name, "dsh-auth-fixture")
  try expectEqual(cookie.headerValue, "dsh-auth-fixture=v1.payload.signature")
}

private func testPromptPayload_addsStableRequestIdentity() throws {
  let payload = DSHPromptPayload(
    requestId: "request-fixture",
    sessionId: "session-fixture",
    mode: .queue,
    content: [.text("hello")])
  let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
  try expectEqual(object?["requestId"] as? String, "request-fixture")
  try expectEqual(object?["sessionId"] as? String, "session-fixture")
}

private func testSessionProjections_decodeSequencedAndMigrationForms() throws {
  let sequenced = try JSONDecoder().decode(DSHSessionProjections.self, from: Data("""
  {"kind":"sequenced","asOfSeq":42,"values":{"title":"Current","todos":null}}
  """.utf8))
  try expect(sequenced.canMerge)
  try expectEqual(sequenced.asOfSeq, 42)
  try expectEqual(sequenced.values.title, "Current")

  let migration = try JSONDecoder().decode(DSHSessionProjections.self, from: Data("""
  {"kind":"migration-required","values":{}}
  """.utf8))
  try expect(!migration.canMerge)
  try expect(migration.asOfSeq == nil)
}

private func testSessionSummary_decodesAgentAvailabilityAndProjectionKind() throws {
  let summary = try JSONDecoder().decode(DSHSessionSummary.self, from: Data("""
  {
    "sessionId":"session-fixture",
    "updatedAt":1234,
    "agentAvailable":true,
    "formatStatus":"current",
    "running":false,
    "blank":true,
    "cwd":"/tmp",
    "projections":{"kind":"sequenced","asOfSeq":2,"values":{"title":null}}
  }
  """.utf8))
  try expect(summary.agentAvailable)
  try expect(summary.isCurrentFormat)
  try expectEqual(summary.projections?.kind, .sequenced)
  try expectEqual(summary.projections?.asOfSeq, 2)
}

private func testZeroPointTwoOptionalFieldsApplyDefaults() throws {
  let permission = try JSONDecoder().decode(
    DSHPermissionSelection.self,
    from: Data(#"{"currentValue":"workspace-write"}"#.utf8))
  try expect(permission.options.isEmpty)
  try expectEqual(permission.currentValue, "workspace-write")
  let provider = try JSONDecoder().decode(
    DSHConfigurableProvider.self,
    from: Data(#"{"provider":"deepseek-official","displayName":"DeepSeek","settingsNs":"llm-deepseek","settingsPath":[]}"#.utf8))
  try expect(!provider.active)
}

private func testProviderClassification_separatesOfficialFromCustomRoutes() throws {
  let providers = try JSONDecoder().decode([DSHConfigurableProvider].self, from: Data("""
  [
    {"provider":"deepseek-official","displayName":"DeepSeek","settingsNs":"llm-deepseek","settingsPath":[]},
    {"provider":"relay","displayName":"Relay","settingsNs":"llm-pi-ai","settingsPath":["providers","relay"],"declared":true},
    {"provider":"amazon-bedrock","displayName":"Bedrock","settingsNs":"llm-pi-ai","settingsPath":["providers","amazon-bedrock"],"declared":false}
  ]
  """.utf8))
  let custom = DSHProviderClassification.customProviderIDs(from: providers)
  try expectEqual(custom, ["relay"])
}

private func testLegacyPresetIDsMapToZeroPointTwoRoster() throws {
  try expectEqual(HarnessController.Preset.standard.hostPresetID, "standard")
  try expectEqual(HarnessController.Preset.code.hostPresetID, "ptc")
  try expectEqual(HarnessController.Preset.minimal.hostPresetID, "minimal")
  try expectEqual(HarnessController.Preset.creator.hostPresetID, "cordis")
  try expectEqual(HarnessController.canonicalHostPresetID("code"), "ptc")
  try expectEqual(HarnessController.canonicalHostPresetID("creator"), "cordis")
}

let dshHostProtocolTests: [NamedTest] = [
  ("Host reconnect policy is bounded and backs off", testHostReconnectPolicy_isBoundedAndBacksOff),
  ("Session follow opening requests a minimal tail", testSessionFollowOpening_requestsMinimalTail),
  ("Sidebar Host status hides routine success states", testSidebarHostStatus_hidesRoutineSuccessStates),
  ("Assistant stream frame decodes live chunk and snapshot buffer", testAssistantStreamFrame_decodesLiveChunkAndSnapshotBuffer),
  ("Follow snapshot decoder preserves records when auxiliary data is invalid", testFollowSnapshotDecoder_preservesRecordsWhenAuxiliaryDataIsInvalid),
  ("DSHJSONPatchValue.init fails for unsupported type", testJSONPatchValue_initFailsForUnsupportedType),
  ("DSHJSONPatchValue.init wraps primitives and null", testJSONPatchValue_initWrapsPrimitivesAndNull),
  ("DSHJSONPatch encodes nested structure as real JSON", testJSONPatch_encodesNestedStructureAsRealJSON),
  ("DSHRPCEnvelope encodes expected shape", testRPCEnvelope_encodesExpectedShape),
  ("DSHRPCServerResponse decodes ok result", testRPCServerResponse_decodesOkResult),
  ("DSHHostDescription decodes bundled runtime shape", testHostDescription_decodesBundledRuntimeShape),
  ("DSHCreateSessionPayload omits nil workspace", testCreateSessionPayload_omitsNilWorkspace),
  ("DSHHostRuntime always suppresses the Web UI", testHostLaunchArguments_alwaysSuppressWebUI),
  ("DSHHostLaunch parses bootstrap token and cookie", testHostLaunch_parsesBootstrapTokenAndCookie),
  ("Prompt payload adds stable request identity", testPromptPayload_addsStableRequestIdentity),
  ("Session projections decode 0.2 forms", testSessionProjections_decodeSequencedAndMigrationForms),
  ("Session summary decodes 0.2 availability", testSessionSummary_decodesAgentAvailabilityAndProjectionKind),
  ("DSH 0.2 optional fields apply defaults", testZeroPointTwoOptionalFieldsApplyDefaults),
  ("Provider classification separates official and custom", testProviderClassification_separatesOfficialFromCustomRoutes),
  ("Legacy preset IDs map to DSH 0.2 roster", testLegacyPresetIDsMapToZeroPointTwoRoster),
]
