import SwiftUI

extension HarnessController {
  static let subagentTreeMaxDepth = 6
  static let subagentTreeMaxNodes = 200

  func loadSubagentTree() {
    guard let hostClient, let root = currentSubagentParentID else { return }
    subagentTreeLoading = true
    subagentTreeTruncated = false
    subagentTree = nil
    let maxDepth = Self.subagentTreeMaxDepth
    let maxNodes = Self.subagentTreeMaxNodes
    Task {
      var visited = 0
      var truncated = false

      func walk(_ parentId: String, depth: Int, path: [SubagentNavigationNode]) async -> [SubagentTreeNode] {
        guard depth < maxDepth, visited < maxNodes,
              let catalog = try? await hostClient.subagents(parentSessionId: parentId) else { return [] }
        var nodes: [SubagentTreeNode] = []
        for entry in catalog.entries {
          guard visited < maxNodes else { truncated = true; break }
          visited += 1
          var node = SubagentTreeNode(entry: entry, depth: depth, ancestorPath: path)
          if entry.kind == "child", let mode = entry.mode, entry.hasChildren == true {
            let address = DSHSubagentAddress(parentSessionId: parentId, childSessionId: entry.id, mode: mode)
            let nextPath = path + [SubagentNavigationNode(address: address, title: entry.label ?? entry.id)]
            node.children = await walk(entry.id, depth: depth + 1, path: nextPath)
          }
          nodes.append(node)
        }
        return nodes
      }

      let tree = await walk(root, depth: 0, path: subagentPath)
      await MainActor.run {
        self.subagentTree = tree
        self.subagentTreeTruncated = truncated
        self.subagentTreeLoading = false
      }
    }
  }

  func openSubagentFromTree(_ node: SubagentTreeNode) {
    guard node.entry.kind == "child" else { return }
    subagentPath = node.ancestorPath
    openSubagent(node.entry)
  }
}

struct SubagentTreeView: View {
  @EnvironmentObject var harness: HarnessController

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("子代理树").font(.title2.weight(.bold))
        Spacer()
        Button(action: harness.loadSubagentTree) { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
        Button("关闭") { harness.showSubagentTree = false }.keyboardShortcut(.cancelAction)
      }

      if harness.subagentTreeTruncated {
        Label("子代理数量较多，树已截断（最多 \(HarnessController.subagentTreeMaxNodes) 个节点 / 深度 \(HarnessController.subagentTreeMaxDepth)）", systemImage: "exclamationmark.triangle")
          .font(.caption).foregroundStyle(.orange)
      }

      if harness.subagentTreeLoading {
        Spacer()
        ProgressView("正在遍历子代理树…")
        Spacer()
      } else if let tree = harness.subagentTree, !tree.isEmpty {
        List(tree.flatMap { $0.flattened() }) { node in
          Button(action: {
            harness.openSubagentFromTree(node)
            harness.showSubagentTree = false
          }) {
            HStack(spacing: 6) {
              Spacer().frame(width: CGFloat(node.depth) * 18)
              Image(systemName: icon(for: node))
                .foregroundStyle(node.entry.activity == "running" ? .blue : node.entry.kind == "diagnostic" ? .orange : .secondary)
              Text(node.entry.label ?? node.entry.id).font(.caption).lineLimit(1)
              Spacer()
              Text(node.entry.kind == "diagnostic" ? (node.entry.reason ?? "不可用") : (node.entry.mode ?? "child"))
                .font(.caption2).foregroundStyle(.secondary)
            }
          }.buttonStyle(.plain).disabled(node.entry.kind != "child")
        }
      } else {
        Spacer()
        Text("没有子代理。").foregroundStyle(.secondary)
        Spacer()
      }
    }
    .padding(20)
    .frame(width: 480, height: 520)
    .onAppear { harness.loadSubagentTree() }
  }

  private func icon(for node: HarnessController.SubagentTreeNode) -> String {
    if node.entry.kind == "diagnostic" { return "exclamationmark.circle" }
    return node.entry.activity == "running" ? "circle.inset.filled" : "circle"
  }
}
