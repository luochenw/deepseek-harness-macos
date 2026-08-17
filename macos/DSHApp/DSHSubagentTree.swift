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
    VStack(alignment: .leading, spacing: DSHSpace.s3) {
      HStack {
        Text("子代理树").font(.title2.weight(.bold)).foregroundStyle(DSHTheme.ink)
        Spacer()
        Button(action: harness.loadSubagentTree) { Image(systemName: "arrow.clockwise") }.buttonStyle(.dshGhost)
        Button("关闭") { harness.showSubagentTree = false }.buttonStyle(.dshSecondary).keyboardShortcut(.cancelAction)
      }

      if harness.subagentTreeTruncated {
        Label("子代理数量较多，树已截断（最多 \(HarnessController.subagentTreeMaxNodes) 个节点 / 深度 \(HarnessController.subagentTreeMaxDepth)）", systemImage: "exclamationmark.triangle")
          .font(.caption.weight(.bold)).foregroundStyle(DSHTheme.warm)
          .padding(DSHSpace.s3)
          .frame(maxWidth: .infinity, alignment: .leading)
          .dshCard(tint: DSHTheme.warmSoft, radius: DSHRadius.md)
      }

      if harness.subagentTreeLoading {
        Spacer()
        ProgressView("正在遍历子代理树…").foregroundStyle(DSHTheme.inkSoft)
        Spacer()
      } else if let tree = harness.subagentTree, !tree.isEmpty {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: DSHSpace.s1) {
            ForEach(tree.flatMap { $0.flattened() }) { node in
              SubagentTreeRow(node: node) {
                harness.openSubagentFromTree(node)
                harness.showSubagentTree = false
              }
            }
          }
        }
      } else {
        Spacer()
        Text("没有子代理。").foregroundStyle(DSHTheme.inkFaint)
        Spacer()
      }
    }
    .padding(DSHSpace.s5)
    .frame(width: 480, height: 520)
    .background(DSHTheme.surface)
    .onAppear { harness.loadSubagentTree() }
  }
}

/// One flattened tree row — background-tinted on hover instead of the List's
/// system separator lines, matching the rest of the redesigned chrome.
private struct SubagentTreeRow: View {
  let node: HarnessController.SubagentTreeNode
  let action: () -> Void
  @State private var isHovering = false

  private var isInteractive: Bool { node.entry.kind == "child" }

  var body: some View {
    Button(action: action) {
      HStack(spacing: DSHSpace.s2) {
        // Structural indent for the manually-walked tree depth, not a
        // visual token — 18pt per level reads correctly at this row height,
        // while a DSHSpace multiple (s2=8 or s3=12) would either cramp deep
        // trees or space shallow ones too loosely.
        Spacer().frame(width: CGFloat(node.depth) * 18)
        Image(systemName: icon)
          .foregroundStyle(iconColor)
        Text(node.entry.label ?? node.entry.id).font(.caption).foregroundStyle(DSHTheme.ink).lineLimit(1)
        Spacer()
        Text(node.entry.kind == "diagnostic" ? (node.entry.reason ?? "不可用") : (node.entry.mode ?? "child"))
          .font(.caption2).foregroundStyle(DSHTheme.inkFaint)
      }
      .padding(.horizontal, DSHSpace.s2)
      .padding(.vertical, DSHSpace.s1)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(isHovering && isInteractive ? DSHTheme.surfaceTint : .clear, in: RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(!isInteractive)
    .onHover { isHovering = $0 }
  }

  private var icon: String {
    if node.entry.kind == "diagnostic" { return "exclamationmark.circle" }
    return node.entry.activity == "running" ? "circle.inset.filled" : "circle"
  }

  private var iconColor: Color {
    node.entry.activity == "running" ? DSHTheme.accentBright : node.entry.kind == "diagnostic" ? DSHTheme.coral : DSHTheme.inkFaint
  }
}
