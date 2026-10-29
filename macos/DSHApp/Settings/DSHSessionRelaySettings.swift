import Foundation

/// 会话互通开关的持久化：往 Host 的 `cordis.patch.yml` 里插入/删除一段
/// 带标记的 insert 块来挂载/卸载 `dsh-tool-session-relay` 插件（让模型看到
/// `list_sessions` / `send_to_session` / `notify_session_on_done` 工具）。
///
/// 不用 UserDefaults 单独记开关状态——直接读文件里标记是否存在，避免和
/// 用户手改 patch 文件产生状态漂移（这份文件里可能还有用户自己写的
/// provider 配置，写入/移除时只动标记内的区块，其余内容原样保留）。
///
/// 见 .agents/notes/implemented/feature/2026-08-17-cross-session-relay.md
enum SessionRelaySettings {
  private static let beginMarker = "# --- dsh-tool-session-relay: begin (managed by DeepSeek Harness settings, do not edit by hand) ---"
  private static let endMarker = "# --- dsh-tool-session-relay: end ---"

  private static var insertBlock: String {
    """
    \(beginMarker)
    - insert:
        - id: tool-session-relay
          name: '@dsh-app/dsh-tool-session-relay'
    \(endMarker)
    """
  }

  private static var dshHome: URL {
    // 与 HarnessController.dshHome 保持完全一致的解析逻辑（main.swift）——
    // 这里不引用它，是为了让这个文件保持零耦合，可以独立编辑不碰
    // main.swift；两处逻辑简单到不值得为共享三行代码而牺牲这个隔离性。
    if let override = ProcessInfo.processInfo.environment["DSH_APP_HOME"], !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/DeepSeek Harness/dsh", isDirectory: true)
  }

  private static var patchFileURL: URL { dshHome.appendingPathComponent("cordis.patch.yml") }

  /// 当前是否已挂载——直接读文件，标记块存在即为开。
  static var enabled: Bool {
    guard let content = try? String(contentsOf: patchFileURL, encoding: .utf8) else { return false }
    return content.contains(beginMarker)
  }

  /// 写入/移除标记块。`cordis.patch.yml` 有 HMR 监听，改动对正在跑的
  /// Host 进程立即生效，不需要重启。
  @discardableResult
  static func setEnabled(_ enabled: Bool) -> Bool {
    let existing = (try? String(contentsOf: patchFileURL, encoding: .utf8)) ?? ""
    let stripped = strippingManagedBlock(from: existing)
    let next: String
    if enabled {
      let separator = stripped.isEmpty || stripped.hasSuffix("\n\n") ? "" : (stripped.hasSuffix("\n") ? "\n" : "\n\n")
      next = stripped + separator + insertBlock + "\n"
    } else {
      next = stripped
    }
    do {
      try FileManager.default.createDirectory(at: dshHome, withIntermediateDirectories: true)
      try next.write(to: patchFileURL, atomically: true, encoding: .utf8)
      return true
    } catch {
      return false
    }
  }

  /// 精确移除标记块之间的内容（含标记本身），折叠残留的多余空行；
  /// 文件里其余手写内容原样保留。循环到找不到下一对标记为止——只删一对
  /// 在正常路径下够用，但万一文件里意外有重复的标记块（崩溃截断的写入、
  /// 手工复制粘贴），只删第一对会让第二份悄悄留下来把插件继续挂着，
  /// 即使开关已经在界面上显示关闭。
  private static func strippingManagedBlock(from content: String) -> String {
    var result = content
    while let beginRange = result.range(of: beginMarker),
          let endRange = result.range(of: endMarker, range: beginRange.upperBound..<result.endIndex) {
      result.removeSubrange(beginRange.lowerBound..<endRange.upperBound)
    }
    result = result.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    return result
  }
}
