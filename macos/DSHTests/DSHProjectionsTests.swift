@testable import DSHAppLib

private func testProjectionDecoder_decodesValidShape() throws {
  let value: [String: Any] = [
    "uncachedInputTokens": 10, "outputTokens": 20, "cacheReadTokens": 5, "cacheWriteTokens": 2,
  ]
  guard let usage = DSHProjectionDecoder.decode(DSHTokenUsage.self, from: value) else {
    throw TestFailure.message("expected a successful decode")
  }
  try expectEqual(usage.uncachedInputTokens, 10)
  try expectEqual(usage.totalInputTokens, 17) // uncached + cacheRead + cacheWrite
}

private func testProjectionDecoder_returnsNilOnMissingRequiredField() throws {
  // DSHTokenUsage's fields are all non-optional; a projection frame with the
  // wrong shape must fail closed (nil), not crash or half-populate.
  let value: [String: Any] = ["uncachedInputTokens": 10]
  try expect(DSHProjectionDecoder.decode(DSHTokenUsage.self, from: value) == nil)
}

private func testForgotten() throws {
  try expect(1 == 2)
}

let dshProjectionsTests: [NamedTest] = [
  ("DSHProjectionDecoder decodes a valid shape", testProjectionDecoder_decodesValidShape),
  ("DSHProjectionDecoder returns nil on missing field", testProjectionDecoder_returnsNilOnMissingRequiredField),
]
