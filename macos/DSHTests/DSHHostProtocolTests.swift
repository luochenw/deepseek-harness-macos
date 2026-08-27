import Foundation
@testable import DSHAppLib

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

private func testCreateSessionPayload_omitsNilWorkspace() throws {
  let data = try JSONEncoder().encode(DSHCreateSessionPayload(cwd: nil, agentPreset: nil))
  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  try expect(payload?.isEmpty == true)
}

let dshHostProtocolTests: [NamedTest] = [
  ("DSHJSONPatchValue.init fails for unsupported type", testJSONPatchValue_initFailsForUnsupportedType),
  ("DSHJSONPatchValue.init wraps primitives and null", testJSONPatchValue_initWrapsPrimitivesAndNull),
  ("DSHJSONPatch encodes nested structure as real JSON", testJSONPatch_encodesNestedStructureAsRealJSON),
  ("DSHRPCEnvelope encodes expected shape", testRPCEnvelope_encodesExpectedShape),
  ("DSHRPCServerResponse decodes ok result", testRPCServerResponse_decodesOkResult),
  ("DSHCreateSessionPayload omits nil workspace", testCreateSessionPayload_omitsNilWorkspace),
]
