import Foundation
@testable import DSHAppLib

private func workspaceDefaults() throws -> (UserDefaults, String) {
  let suite = "DSHWorkspaceTests.\(UUID().uuidString)"
  guard let defaults = UserDefaults(suiteName: suite) else {
    throw TestFailure.message("failed to create isolated UserDefaults suite")
  }
  defaults.removePersistentDomain(forName: suite)
  return (defaults, suite)
}

private func testWorkspacePreference_usesDefaultForFirstLaunch() throws {
  let (defaults, suite) = try workspaceDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }
  let fallback = FileManager.default.temporaryDirectory
    .appendingPathComponent("DSHWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: fallback) }

  let restored = DSHWorkspacePreference.restoredWorkspace(defaults: defaults, defaultURL: fallback)

  try expectEqual(restored, fallback.standardizedFileURL)
  try expectEqual(defaults.string(forKey: DSHWorkspacePreference.workspaceKey), fallback.standardizedFileURL.path)
  try expect(FileManager.default.fileExists(atPath: fallback.path))
}

private func testWorkspacePreference_persistsExplicitNoWorkspace() throws {
  let (defaults, suite) = try workspaceDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }
  let previous = URL(fileURLWithPath: "/tmp/previous-workspace", isDirectory: true)
  let fallback = URL(fileURLWithPath: "/tmp/fallback-workspace", isDirectory: true)
  DSHWorkspacePreference.persist(previous, defaults: defaults)

  DSHWorkspacePreference.persist(nil, defaults: defaults)
  let restored = DSHWorkspacePreference.restoredWorkspace(defaults: defaults, defaultURL: fallback)

  try expect(restored == nil)
  try expect(defaults.bool(forKey: DSHWorkspacePreference.noWorkspaceKey))
  try expect(defaults.string(forKey: DSHWorkspacePreference.workspaceKey) == nil)
}

private func testWorkspacePreference_selectingDirectoryClearsNoWorkspace() throws {
  let (defaults, suite) = try workspaceDefaults()
  defer { defaults.removePersistentDomain(forName: suite) }
  let selected = FileManager.default.temporaryDirectory
    .appendingPathComponent("DSHWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: selected) }
  DSHWorkspacePreference.persist(nil, defaults: defaults)

  DSHWorkspacePreference.persist(selected, defaults: defaults)
  let restored = DSHWorkspacePreference.restoredWorkspace(defaults: defaults, defaultURL: nil)

  try expectEqual(restored, selected.standardizedFileURL)
  try expect(defaults.object(forKey: DSHWorkspacePreference.noWorkspaceKey) == nil)
}

private func testWorkspaceContext_omitsRegisteredFoldersWithoutActiveWorkspace() throws {
  let registered = [
    DSHWorkspaceView(workspaceId: "one", path: "/tmp/one", title: "One", sessionIds: []),
    DSHWorkspaceView(workspaceId: "two", path: "/tmp/two", title: "Two", sessionIds: []),
  ]

  try expect(DSHWorkspaceContext.additionalFolders(activeWorkspace: nil, registered: registered).isEmpty)
}

private func testWorkspaceContext_excludesOnlyActiveWorkspace() throws {
  let registered = [
    DSHWorkspaceView(workspaceId: "one", path: "/tmp/one", title: "One", sessionIds: []),
    DSHWorkspaceView(workspaceId: "two", path: "/tmp/two", title: "Two", sessionIds: []),
  ]

  let extras = DSHWorkspaceContext.additionalFolders(
    activeWorkspace: URL(fileURLWithPath: "/tmp/one", isDirectory: true),
    registered: registered)

  try expectEqual(extras.map(\.workspaceId), ["two"])
}

let dshWorkspaceTests: [NamedTest] = [
  ("Workspace preference uses default on first launch", testWorkspacePreference_usesDefaultForFirstLaunch),
  ("Workspace preference persists explicit no-workspace selection", testWorkspacePreference_persistsExplicitNoWorkspace),
  ("Workspace preference clears no-workspace when a directory is selected", testWorkspacePreference_selectingDirectoryClearsNoWorkspace),
  ("Workspace context omits folders without an active workspace", testWorkspaceContext_omitsRegisteredFoldersWithoutActiveWorkspace),
  ("Workspace context excludes only the active workspace", testWorkspaceContext_excludesOnlyActiveWorkspace),
]
