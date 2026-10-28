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

private func testProjectionDecoder_decodesNestedTokenTotals() throws {
  let value: [String: Any] = [
    "totals": [
      "uncachedInputTokens": 113_342,
      "outputTokens": 65_696,
      "cacheReadTokens": 6_230_272,
      "cacheWriteTokens": 0,
    ],
    "last": ["turn": 1, "step": 2],
  ]
  guard let usage = DSHProjectionDecoder.decode(DSHTokenUsage.self, from: value) else {
    throw TestFailure.message("expected nested totals to decode")
  }
  try expectEqual(usage.uncachedInputTokens, 113_342)
  try expectEqual(usage.outputTokens, 65_696)
  try expectEqual(usage.cacheReadTokens, 6_230_272)
}

private func testExactProjections_restoreUsageAfterSessionNavigation() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.hostCurrentSessionID = "session-usage"
    let usage = DSHTokenUsage(
      uncachedInputTokens: 120,
      outputTokens: 48,
      cacheReadTokens: 280,
      cacheWriteTokens: 12)
    let pressure = DSHContextPressure(
      pressureTokens: 164_131,
      projectedTokens: nil,
      contextWindow: 1_048_576,
      surfaceTokens: 140_303)
    let stats = DSHSessionStats(turns: 2, steps: 9, llmMs: 1_200, toolMs: 300)
    let projections = DSHSessionProjections(
      asOfSeq: 42,
      values: DSHSessionProjectionValues(
        title: "Usage",
        todos: nil,
        plan: nil,
        goal: nil,
        tokenUsage: usage,
        contextPressure: pressure,
        sessionStats: stats))

    harness.applyExactSessionProjections(projections, sessionID: "session-usage")

    try expectEqual(harness.tokenUsage?.totalInputTokens, 412)
    try expectEqual(harness.contextPressure?.pressureTokens, 164_131)
    try expectEqual(harness.sessionStats?.steps, 9)
  }
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

private func testModelUsagePresentation_fallsBackFromZeroPressureAndUsesMillions() throws {
  let pressure = DSHContextPressure(
    pressureTokens: 0,
    projectedTokens: 0,
    contextWindow: 1_048_576,
    surfaceTokens: 140_303)
  try expectEqual(DSHModelUsagePresentation.contextTokens(pressure), 140_303)
  try expectEqual(DSHModelUsagePresentation.compact(1_048_576), "1.0m")
  try expectEqual(DSHModelUsagePresentation.compact(428_315_000), "428m")
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
  ("DSHProjectionDecoder decodes nested token totals", testProjectionDecoder_decodesNestedTokenTotals),
  ("Exact projections restore usage after navigation", testExactProjections_restoreUsageAfterSessionNavigation),
  ("Model usage presentation prefers projected context and calculates cache rate", testModelUsagePresentation_usesProjectedContextAndCacheRate),
  ("Model usage presentation handles missing capacity and zero input", testModelUsagePresentation_handlesMissingCapacityAndZeroInput),
  ("Model usage presentation falls back from zero pressure and uses millions", testModelUsagePresentation_fallsBackFromZeroPressureAndUsesMillions),
  ("DSHProjectionDecoder returns nil on missing field", testProjectionDecoder_returnsNilOnMissingRequiredField),
]
