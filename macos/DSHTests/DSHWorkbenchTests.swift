import Foundation
@testable import DSHAppLib

private func testWorkbenchContext_closesSelectedTabToRightNeighbor() throws {
  let first = DSHWorkbenchTab(kind: .execution, title: "执行")
  let second = DSHWorkbenchTab(kind: .agents, title: "Agent")
  let third = DSHWorkbenchTab(kind: .browser, title: "浏览器")
  var context = DSHWorkbenchContext(tabs: [first, second, third], selectedTabID: second.id)

  try expect(context.close(second.id))
  try expectEqual(context.selectedTabID, third.id)
  try expectEqual(context.tabs.map(\.id), [first.id, third.id])
}

private func testWorkbenchContext_closesLastSelectedTabToLeftNeighbor() throws {
  let first = DSHWorkbenchTab(kind: .execution, title: "执行")
  let second = DSHWorkbenchTab(kind: .agents, title: "Agent")
  var context = DSHWorkbenchContext(tabs: [first, second], selectedTabID: second.id)

  try expect(context.close(second.id))
  try expectEqual(context.selectedTabID, first.id)
}

private func testWorkbenchLayout_fitsRegularWindowWithoutOverflow() throws {
  let main = DSHMainWindowLayout.resolve(totalWidth: 1180)
  let split = DSHWorkbenchSplitLayout.resolve(
    availableWidth: 1180 - main.sidebarWidth,
    compact: main.compact,
    workbenchVisible: true,
    preferredWorkbenchWidth: 520)

  try expectEqual(main.sidebarWidth, 290)
  try expect(!main.compact)
  try expectEqual(split.conversationWidth, 500)
  try expectEqual(split.workbenchWidth, 383)
  try expectEqual(
    main.sidebarWidth
      + split.conversationWidth
      + DSHWorkbenchSplitLayout.resizeHandleWidth
      + (split.workbenchWidth ?? 0),
    1180)
}

private func testWorkbenchLayout_compactsAtScreenshotWidth() throws {
  let main = DSHMainWindowLayout.resolve(totalWidth: 1024)
  let split = DSHWorkbenchSplitLayout.resolve(
    availableWidth: 1024 - main.sidebarWidth,
    compact: main.compact,
    workbenchVisible: true,
    preferredWorkbenchWidth: 520)

  try expectEqual(main.sidebarWidth, 260)
  try expect(main.compact)
  try expectEqual(split.conversationWidth, 420)
  try expectEqual(split.workbenchWidth, 337)
  try expect(DSHComposerLayout.usesStackedControls(
    availableWidth: split.conversationWidth))
  try expectEqual(
    main.sidebarWidth
      + split.conversationWidth
      + DSHWorkbenchSplitLayout.resizeHandleWidth
      + (split.workbenchWidth ?? 0),
    1024)
}

private func testWorkbenchLayout_fitsMinimumWindow() throws {
  let main = DSHMainWindowLayout.resolve(totalWidth: DSHMainWindowLayout.minimumWidth)
  let split = DSHWorkbenchSplitLayout.resolve(
    availableWidth: DSHMainWindowLayout.minimumWidth - main.sidebarWidth,
    compact: main.compact,
    workbenchVisible: true,
    preferredWorkbenchWidth: 520)

  try expectEqual(main.sidebarWidth, 260)
  try expectEqual(split.conversationWidth, 420)
  try expectEqual(split.workbenchWidth, 313)
  try expectEqual(
    main.sidebarWidth
      + split.conversationWidth
      + DSHWorkbenchSplitLayout.resizeHandleWidth
      + (split.workbenchWidth ?? 0),
    DSHMainWindowLayout.minimumWidth)
}

private func testWorkbenchLayout_temporarilyHidesBelowInlineThreshold() throws {
  let main = DSHMainWindowLayout.resolve(totalWidth: 960)
  let split = DSHWorkbenchSplitLayout.resolve(
    availableWidth: 960 - main.sidebarWidth,
    compact: main.compact,
    workbenchVisible: true,
    preferredWorkbenchWidth: 520)

  try expectEqual(main.sidebarWidth, 260)
  try expectEqual(split.conversationWidth, 700)
  try expect(split.workbenchWidth == nil)
  try expect(DSHComposerLayout.usesStackedControls(
    availableWidth: split.conversationWidth))
}

private func testBrowserURL_normalizesLocalAndPublicHosts() throws {
  try MainActor.assumeIsolated {
    try expectEqual(DSHBrowserRuntime.normalizedURL(from: "localhost:5173")?.absoluteString, "http://localhost:5173")
    try expectEqual(DSHBrowserRuntime.normalizedURL(from: "127.0.0.1:8080/status")?.scheme, "http")
    try expectEqual(DSHBrowserRuntime.normalizedURL(from: "example.com/docs")?.scheme, "https")
    try expectEqual(DSHBrowserRuntime.normalizedURL(from: "https://example.com/docs")?.absoluteString, "https://example.com/docs")
    try expectEqual(DSHBrowserRuntime.normalizedURL(from: "//example.com/a")?.absoluteString, "https://example.com/a")
    try expect(DSHBrowserRuntime.normalizedURL(from: "   ") == nil)
  }
}

private func testWorkbench_migratesDefaultTabsToLocalAndHostSession() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.openExecutionWorkbench()
    try expectEqual(harness.workbenchTabs.map(\.title), ["执行"])

    let localID = harness.insertLocalSessionRow()
    try expectEqual(harness.workbenchTabs.map(\.title), ["执行"])

    harness.sessions[0].hostSessionId = "host-session"
    harness.hostCurrentSessionID = "host-session"
    harness.migrateWorkbenchContext(localSessionID: localID, hostSessionID: "host-session")
    try expectEqual(harness.workbenchTabs.map(\.title), ["执行"])
  }
}

private func testWorkbench_rootToolStaysLiveWhileViewingSubagent() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.hostCurrentSessionID = "root-session"
    let initial = HarnessController.ToolActivity(
      callId: "root-tool",
      name: "Read",
      summary: "正在运行",
      state: .running,
      output: "",
      presentation: nil)
    harness.activeTools = [initial]
    harness.openToolWorkbench(initial)
    guard let tab = harness.selectedWorkbenchTab else {
      throw TestFailure.message("expected a tool tab")
    }

    var settled = initial
    settled.state = .succeeded
    settled.output = "done"
    harness.activeTools = [settled]
    harness.activeSubagentAddress = DSHSubagentAddress(
      parentSessionId: "root-session",
      childSessionId: "child-session",
      mode: "continuable")

    try expectEqual(harness.toolActivity(for: tab)?.output, "done")
  }
}

private func testMarkdownHeadings_andRelativeLinksUseDocumentDirectory() throws {
  try MainActor.assumeIsolated {
    let headings = MarkdownText.headings(in: "# Overview\n\n## API Surface\n\n## API Surface\n")
    try expectEqual(headings.map(\.anchor), ["overview", "api-surface", "api-surface-1"])
  }

  let document = URL(fileURLWithPath: "/tmp/docs/guide.md")
  let resolved = HarnessController.resolvedMarkdownLink(
    URL(string: "../README.md")!,
    documentURL: document)
  try expectEqual(resolved.path, "/tmp/README.md")
  let encoded = HarnessController.resolvedMarkdownLink(
    URL(string: "My%20File.md")!,
    documentURL: document)
  try expectEqual(encoded.path, "/tmp/docs/My File.md")
  let anchored = HarnessController.resolvedMarkdownLink(
    URL(string: "My%20File.md#API%20Surface")!,
    documentURL: document)
  try expectEqual(anchored.path, "/tmp/docs/My File.md")
  try expectEqual(anchored.fragment?.removingPercentEncoding, "API Surface")
}

private func testMarkdownDocument_reloadsInPlaceWrites() throws {
  try MainActor.assumeIsolated {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("DSHMarkdownMonitor-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("notes.md")
    try "# Before\n".write(to: file, atomically: false, encoding: .utf8)
    let document = DSHMarkdownDocumentState(url: file)
    defer { document.stopMonitoring() }

    let initialDeadline = Date().addingTimeInterval(2)
    while Date() < initialDeadline, document.text != "# Before\n" {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    try expectEqual(document.text, "# Before\n")

    try "# After\n".write(to: file, atomically: false, encoding: .utf8)
    let reloadDeadline = Date().addingTimeInterval(3)
    while Date() < reloadDeadline, document.text != "# After\n" {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    try expectEqual(document.text, "# After\n")
  }
}

private func testWorkbench_closingBrowserReleasesRuntime() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.hostCurrentSessionID = "root-session"
    weak var released: DSHBrowserRuntime?
    autoreleasepool {
      harness.newBrowserWorkbench()
      guard let tab = harness.selectedWorkbenchTab,
            let runtime = harness.browserRuntime(for: tab.id) else {
        return
      }
      released = runtime
      harness.closeWorkbenchTab(tab.id)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    try expect(released == nil)
  }
}

private func testRestrictedBrowser_rejectsLocalFileNavigation() throws {
  try MainActor.assumeIsolated {
    let runtime = DSHBrowserRuntime(restrictToHTTP: true)
    defer { runtime.stop() }
    var openedFile = false
    runtime.onOpenFile = { _ in openedFile = true }

    runtime.navigate(to: URL(fileURLWithPath: "/tmp/private.md"))

    try expect(!openedFile)
    try expectEqual(runtime.errorMessage, "模型打开的浏览器标签仅允许 HTTP(S) 页面。")
  }
}

private func testWorkbench_discardsArchivedContexts() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.hostCurrentSessionID = "archived-session"
    weak var released: DSHBrowserRuntime?
    autoreleasepool {
      harness.newBrowserWorkbench()
      guard let tab = harness.selectedWorkbenchTab else { return }
      released = harness.browserRuntime(for: tab.id)
      harness.discardArchivedWorkbenchContexts(hostSessionIDs: ["archived-session"])
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))

    try expect(harness.workbenchTabs.isEmpty)
    try expect(released == nil)
  }
}

private func testModelWorkbenchTool_decodesBrowserRequests() throws {
  try MainActor.assumeIsolated {
    let request = try DSHModelWorkbenchTool.decode(
      data: [
        "name": DSHModelWorkbenchTool.browserName,
        "arguments": #"{"url":"localhost:5173/docs"}"#,
      ],
      workingDirectory: nil)
    try expectEqual(request, .browser(URL(string: "http://localhost:5173/docs")!))
    try expectThrows {
      _ = try DSHModelWorkbenchTool.decode(
        data: [
          "name": DSHModelWorkbenchTool.browserName,
          "arguments": #"{"url":"file:///tmp/README.md"}"#,
        ],
        workingDirectory: nil)
    }
  }
}

private func testModelWorkbenchTool_confinesMarkdownToSessionCwd() throws {
  try MainActor.assumeIsolated {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("DSHModelWorkbench-\(UUID().uuidString)", isDirectory: true)
    let outside = FileManager.default.temporaryDirectory
      .appendingPathComponent("DSHModelWorkbenchOutside-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    let guide = root.appendingPathComponent("docs/guide.md")
    try FileManager.default.createDirectory(
      at: guide.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try "# Guide\n".write(to: guide, atomically: true, encoding: .utf8)
    let outsideFile = outside.appendingPathComponent("secret.md")
    try "# Secret\n".write(to: outsideFile, atomically: true, encoding: .utf8)
    let symlink = root.appendingPathComponent("escape.md")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outsideFile)

    let request = try DSHModelWorkbenchTool.decode(
      data: [
        "name": DSHModelWorkbenchTool.markdownName,
        "arguments": #"{"path":" docs/guide.md ","anchor":"api"}"#,
      ],
      workingDirectory: root)
    try expectEqual(request, .markdown(guide.resolvingSymlinksInPath(), anchor: "api"))
    try expectThrows {
      _ = try DSHModelWorkbenchTool.decode(
        data: [
          "name": DSHModelWorkbenchTool.markdownName,
          "arguments": #"{"path":"escape.md"}"#,
        ],
        workingDirectory: root)
    }
    try expectThrows {
      _ = try DSHModelWorkbenchTool.decode(
        data: [
          "name": DSHModelWorkbenchTool.markdownName,
          "arguments": #"{"path":"docs/guide.txt"}"#,
        ],
        workingDirectory: root)
    }
  }
}

private func testVerifiedFile_readsWithinBoundaryAndEnforcesLimit() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("DSHVerifiedFile-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let file = root.appendingPathComponent("guide.md")
  try Data("hello".utf8).write(to: file)

  try expectEqual(
    try DSHVerifiedFile.readData(file, within: root, maxBytes: 5),
    Data("hello".utf8))
  try expectThrows {
    _ = try DSHVerifiedFile.readData(file, within: root, maxBytes: 4)
  }
}

private func testModelWorkbenchTool_ignoresUnknownTools() throws {
  try MainActor.assumeIsolated {
    let request = try DSHModelWorkbenchTool.decode(
      data: ["name": "read", "arguments": #"{"file_path":"README.md"}"#],
      workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true))
    try expect(request == nil)
  }
}

private func testModelWorkbenchEvents_allowRepeatedCallIDsAcrossTurns() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let session = HarnessController.Session(
      title: "root",
      workspaceName: "workspace",
      updatedAt: Date(),
      messages: [],
      hostSessionId: "root-session")
    harness.sessions = [session]
    harness.selectedSessionID = session.id
    harness.hostCurrentSessionID = "root-session"

    for (turn, path) in [(0, "first"), (1, "second")] {
      harness.consumeModelWorkbenchEvent(
        sessionID: "root-session",
        event: [
          "type": "tool/call",
          "data": [
            "turn": turn,
            "step": 0,
            "callId": "call-0",
            "name": DSHModelWorkbenchTool.browserName,
            "arguments": ["url": "https://example.com/\(path)"],
          ],
        ])
      harness.consumeModelWorkbenchEvent(
        sessionID: "root-session",
        event: [
          "seq": turn + 1,
          "type": "tool/result",
          "data": [
            "turn": turn,
            "step": 0,
            "callId": "call-0",
            "result": "requested",
          ],
        ])
    }

    try expectEqual(harness.workbenchTabs.count, 2)
  }
}

private func testModelWorkbenchEvents_retrySettledSubagentAfterSessionRefresh() throws {
  try MainActor.assumeIsolated {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("DSHModelWorkbenchRetry-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "# Guide\n".write(
      to: root.appendingPathComponent("guide.md"),
      atomically: true,
      encoding: .utf8)

    let harness = HarnessController(startRuntime: false)
    let session = HarnessController.Session(
      title: "root",
      workspaceName: root.lastPathComponent,
      updatedAt: Date(),
      messages: [],
      hostSessionId: "root-session")
    harness.sessions = [session]
    harness.selectedSessionID = session.id
    harness.hostCurrentSessionID = "root-session"
    harness.consumeModelWorkbenchEvent(
      sessionID: "child-session",
      event: [
        "type": "tool/call",
        "data": [
          "turn": 0,
          "step": 0,
          "callId": "call-1",
          "name": DSHModelWorkbenchTool.markdownName,
          "arguments": ["path": "guide.md"],
        ],
      ])
    harness.consumeModelWorkbenchEvent(
      sessionID: "child-session",
      event: [
        "seq": 2,
        "type": "tool/result",
        "data": [
          "turn": 0,
          "step": 0,
          "callId": "call-1",
          "result": "requested",
        ],
      ])
    try expect(harness.workbenchTabs.isEmpty)

    harness.hostSessions = [
      DSHSessionSummary(
        sessionId: "root-session",
        updatedAt: 0,
        running: true,
        blank: false,
        cwd: root.path,
        agentPreset: nil,
        parentSessionId: nil,
        origin: nil,
        projections: nil),
      DSHSessionSummary(
        sessionId: "child-session",
        updatedAt: 0,
        running: true,
        blank: false,
        cwd: root.path,
        agentPreset: nil,
        parentSessionId: "root-session",
        origin: nil,
        projections: nil),
    ]
    harness.resumePendingModelWorkbenchRequests()

    try expectEqual(harness.workbenchTabs.count, 1)
  }
}

private func testModelWorkbenchEvents_openOnlyAfterSuccessfulSettlement() throws {
  try MainActor.assumeIsolated {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("DSHModelWorkbenchEvents-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let guide = root.appendingPathComponent("guide.md")
    try "# Guide\n".write(to: guide, atomically: true, encoding: .utf8)

    let harness = HarnessController(startRuntime: false)
    let session = HarnessController.Session(
      title: "root",
      workspaceName: root.lastPathComponent,
      updatedAt: Date(),
      messages: [],
      hostSessionId: "root-session")
    harness.sessions = [session]
    harness.selectedSessionID = session.id
    harness.hostCurrentSessionID = "root-session"
    harness.workspace = root

    let call: [String: Any] = [
      "type": "tool/call",
      "data": [
        "callId": "call-1",
        "name": DSHModelWorkbenchTool.markdownName,
        "arguments": #"{"path":"guide.md"}"#,
      ],
    ]
    harness.consumeModelWorkbenchEvent(sessionID: "root-session", event: call)
    try expect(harness.workbenchTabs.isEmpty)

    harness.consumeModelWorkbenchEvent(
      sessionID: "root-session",
      event: [
        "type": "tool/result",
        "data": [
          "callId": "call-1",
          "error": ["code": "DENIED"],
        ],
      ])
    try expect(harness.workbenchTabs.isEmpty)

    var succeedingCall = call
    succeedingCall["data"] = [
      "callId": "call-2",
      "name": DSHModelWorkbenchTool.markdownName,
      "arguments": #"{"path":"guide.md"}"#,
    ]
    harness.consumeModelWorkbenchEvent(sessionID: "root-session", event: succeedingCall)
    harness.consumeModelWorkbenchEvent(
      sessionID: "root-session",
      event: [
        "type": "tool/result",
        "data": ["callId": "call-2", "result": "requested"],
      ])
    try expectEqual(harness.workbenchTabs.count, 1)
    harness.consumeModelWorkbenchEvent(
      sessionID: "root-session",
      event: [
        "type": "tool/result",
        "data": ["callId": "call-2", "result": "requested"],
      ])
    try expectEqual(harness.workbenchTabs.count, 1)
    harness.consumeModelWorkbenchEvent(
      sessionID: "root-session",
      event: [
        "type": "tool/call",
        "data": [
          "callId": "call-3",
          "name": DSHModelWorkbenchTool.markdownName,
          "arguments": #"{"path":"guide.md"}"#,
        ],
      ])
    harness.consumeModelWorkbenchEvent(
      sessionID: "root-session",
      event: ["type": "turn/end", "data": [:]])
    harness.consumeModelWorkbenchEvent(
      sessionID: "root-session",
      event: [
        "type": "tool/result",
        "data": ["callId": "call-3", "result": "requested"],
      ])
    try expectEqual(harness.workbenchTabs.count, 1)
  }
}

private func testModelWorkbenchEvents_supportSuccessfulCodeDispatch() throws {
  try MainActor.assumeIsolated {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("DSHModelWorkbenchCode-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let guide = root.appendingPathComponent("guide.md")
    try "# Guide\n".write(to: guide, atomically: true, encoding: .utf8)

    let harness = HarnessController(startRuntime: false)
    let session = HarnessController.Session(
      title: "root",
      workspaceName: root.lastPathComponent,
      updatedAt: Date(),
      messages: [],
      hostSessionId: "root-session")
    harness.sessions = [session]
    harness.selectedSessionID = session.id
    harness.hostCurrentSessionID = "root-session"
    harness.workspace = root
    harness.consumeModelWorkbenchEvent(
      sessionID: "root-session",
      event: [
        "type": "tool/code-dispatch-start",
        "data": [
          "subCallId": "root:code:0",
          "name": DSHModelWorkbenchTool.markdownName,
          "arguments": ["path": "guide.md"],
        ],
      ])
    harness.consumeModelWorkbenchEvent(
      sessionID: "root-session",
      event: [
        "type": "tool/code-dispatch",
        "data": [
          "subCallId": "root:code:0",
          "name": DSHModelWorkbenchTool.markdownName,
          "arguments": ["path": "guide.md"],
          "isError": true,
        ],
      ])
    try expect(harness.workbenchTabs.isEmpty)
    harness.consumeModelWorkbenchEvent(
      sessionID: "root-session",
      event: [
        "type": "tool/code-dispatch-start",
        "data": [
          "subCallId": "root:code:1",
          "name": DSHModelWorkbenchTool.markdownName,
          "arguments": ["path": "guide.md"],
        ],
      ])
    harness.consumeModelWorkbenchEvent(
      sessionID: "root-session",
      event: [
        "type": "tool/code-dispatch",
        "data": [
          "subCallId": "root:code:1",
          "name": DSHModelWorkbenchTool.markdownName,
          "arguments": ["path": "guide.md"],
          "isError": false,
        ],
      ])
    try expectEqual(harness.workbenchTabs.count, 1)
  }
}

private func testModelWorkbenchEvents_keepBackgroundSessionOwnership() throws {
  try MainActor.assumeIsolated {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("DSHModelWorkbenchBackground-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "# Guide\n".write(
      to: root.appendingPathComponent("guide.md"),
      atomically: true,
      encoding: .utf8)

    let harness = HarnessController(startRuntime: false)
    let foreground = HarnessController.Session(
      title: "foreground",
      workspaceName: "foreground",
      updatedAt: Date(),
      messages: [],
      hostSessionId: "foreground-session")
    let background = HarnessController.Session(
      title: "background",
      workspaceName: root.lastPathComponent,
      updatedAt: Date(),
      messages: [],
      hostSessionId: "background-session")
    harness.sessions = [foreground, background]
    harness.selectedSessionID = foreground.id
    harness.hostCurrentSessionID = "foreground-session"
    harness.hostSessions = [
      DSHSessionSummary(
        sessionId: "background-session",
        updatedAt: 0,
        running: true,
        blank: false,
        cwd: root.path,
        agentPreset: nil,
        parentSessionId: nil,
        origin: nil,
        projections: nil),
    ]

    harness.consumeModelWorkbenchEvent(
      sessionID: "background-session",
      event: [
        "type": "tool/call",
        "data": [
          "callId": "background-call",
          "name": DSHModelWorkbenchTool.markdownName,
          "arguments": #"{"path":"guide.md"}"#,
        ],
      ])
    harness.consumeModelWorkbenchEvent(
      sessionID: "background-session",
      event: [
        "type": "tool/result",
        "data": ["callId": "background-call", "result": "requested"],
      ])
    try expect(harness.workbenchTabs.isEmpty)
    try expect(!harness.showDetails)

    harness.selectedSessionID = background.id
    harness.hostCurrentSessionID = "background-session"
    try expectEqual(harness.workbenchTabs.count, 1)
  }
}

private func testMarkdownResources_respectModelDocumentBoundary() throws {
  try MainActor.assumeIsolated {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("DSHMarkdownResources-\(UUID().uuidString)", isDirectory: true)
    let outside = FileManager.default.temporaryDirectory
      .appendingPathComponent("DSHMarkdownResourcesOutside-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    let local = root.appendingPathComponent("image.png")
    let secret = outside.appendingPathComponent("secret.png")
    try Data([0]).write(to: local)
    try Data([1]).write(to: secret)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("escape.png"),
      withDestinationURL: secret)

    try expectEqual(
      MarkdownText.resourceURL(
        "image.png",
        baseURL: root,
        allowedFileRoot: root),
      local.resolvingSymlinksInPath())
    try expect(
      MarkdownText.resourceURL(
        "../\(outside.lastPathComponent)/secret.png",
        baseURL: root,
        allowedFileRoot: root) == nil)
    try expect(
      MarkdownText.resourceURL(
        "escape.png",
        baseURL: root,
        allowedFileRoot: root) == nil)
    try expect(
      MarkdownText.resourceURL(
        "file:///tmp/secret.png",
        baseURL: nil,
        allowedFileRoot: nil) == nil)
  }
}

let dshWorkbenchTests: [NamedTest] = [
  ("Workbench closes selected tab to its right neighbor", testWorkbenchContext_closesSelectedTabToRightNeighbor),
  ("Workbench closes last selected tab to its left neighbor", testWorkbenchContext_closesLastSelectedTabToLeftNeighbor),
  ("Workbench layout fits the regular window", testWorkbenchLayout_fitsRegularWindowWithoutOverflow),
  ("Workbench layout compacts at screenshot width", testWorkbenchLayout_compactsAtScreenshotWidth),
  ("Workbench layout fits the minimum window", testWorkbenchLayout_fitsMinimumWindow),
  ("Workbench layout hides below the inline threshold", testWorkbenchLayout_temporarilyHidesBelowInlineThreshold),
  ("Browser URL normalizes local and public hosts", testBrowserURL_normalizesLocalAndPublicHosts),
  ("Workbench migrates default tabs to local and Host sessions", testWorkbench_migratesDefaultTabsToLocalAndHostSession),
  ("Workbench root tool stays live while viewing a subagent", testWorkbench_rootToolStaysLiveWhileViewingSubagent),
  ("Markdown headings and relative links use the document directory", testMarkdownHeadings_andRelativeLinksUseDocumentDirectory),
  ("Markdown document reloads in-place writes", testMarkdownDocument_reloadsInPlaceWrites),
  ("Workbench closing a browser releases its runtime", testWorkbench_closingBrowserReleasesRuntime),
  ("Restricted browser rejects local file navigation", testRestrictedBrowser_rejectsLocalFileNavigation),
  ("Workbench discards archived contexts", testWorkbench_discardsArchivedContexts),
  ("Model workbench tool decodes browser requests", testModelWorkbenchTool_decodesBrowserRequests),
  ("Model workbench tool confines Markdown to session cwd", testModelWorkbenchTool_confinesMarkdownToSessionCwd),
  ("Verified file reads within boundary and enforces limit", testVerifiedFile_readsWithinBoundaryAndEnforcesLimit),
  ("Model workbench tool ignores unrelated tools", testModelWorkbenchTool_ignoresUnknownTools),
  ("Model workbench events open only after successful settlement", testModelWorkbenchEvents_openOnlyAfterSuccessfulSettlement),
  ("Model workbench events support successful Code Mode dispatch", testModelWorkbenchEvents_supportSuccessfulCodeDispatch),
  ("Model workbench events allow repeated call IDs across turns", testModelWorkbenchEvents_allowRepeatedCallIDsAcrossTurns),
  ("Model workbench events retry settled subagent calls", testModelWorkbenchEvents_retrySettledSubagentAfterSessionRefresh),
  ("Model workbench events keep background session ownership", testModelWorkbenchEvents_keepBackgroundSessionOwnership),
  ("Markdown resources respect model document boundaries", testMarkdownResources_respectModelDocumentBoundary),
]
