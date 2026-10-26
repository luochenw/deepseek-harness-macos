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

private func testModelUsagePresentation_usesProjectedContextAndCacheRate() throws {
  let pressure = DSHContextPressure(pressureTokens: 800, projectedTokens: 1_000, contextWindow: 2_000)
  let usage = DSHTokenUsage(uncachedInputTokens: 200, outputTokens: 100, cacheReadTokens: 600, cacheWriteTokens: 200)
  try expectEqual(DSHModelUsagePresentation.contextTokens(pressure), 1_000)
  try expectEqual(DSHModelUsagePresentation.contextPercent(pressure), 50)
  try expectEqual(DSHModelUsagePresentation.cacheHitRate(usage), 60)
}

private func testModelUsagePresentation_handlesMissingCapacityAndZeroInput() throws {
  let pressure = DSHContextPressure(pressureTokens: 800, projectedTokens: nil, contextWindow: nil)
  let usage = DSHTokenUsage(uncachedInputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)
  try expectEqual(DSHModelUsagePresentation.contextTokens(pressure), 800)
  try expect(DSHModelUsagePresentation.contextPercent(pressure) == nil)
  try expect(DSHModelUsagePresentation.cacheHitRate(usage) == nil)
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
  ("Model usage presentation prefers projected context and calculates cache rate", testModelUsagePresentation_usesProjectedContextAndCacheRate),
  ("Model usage presentation handles missing capacity and zero input", testModelUsagePresentation_handlesMissingCapacityAndZeroInput),
  ("DSHProjectionDecoder returns nil on missing field", testProjectionDecoder_returnsNilOnMissingRequiredField),
]
