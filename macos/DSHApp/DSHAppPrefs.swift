import Foundation

/// 客户端本地偏好（设置 → 通用）。纯 UI 行为开关，存 UserDefaults，
/// 与 Host 的 settings.yaml 无关。默认值语义统一为"未写过 = 开"，
/// 与设置页 @AppStorage 的默认参数保持一致。
enum AppPrefs {
  /// 回车发送（关闭后回车换行、⌘回车发送；Shift+回车始终换行）。
  static let enterToSendKey = "dsh.composer.enterToSend"
  static var enterToSend: Bool { boolDefaultingTrue(enterToSendKey) }

  /// 回合完成时的系统通知横幅（菜单栏状态图标不受影响）。
  static let notifyTurnEndKey = "dsh.alerts.notifyTurnEnd"
  static var notifyTurnEnd: Bool { boolDefaultingTrue(notifyTurnEndKey) }

  /// 需要审批 / 提问时的系统通知横幅与 Dock 弹跳。
  static let notifyAttentionKey = "dsh.alerts.notifyAttention"
  static var notifyAttention: Bool { boolDefaultingTrue(notifyAttentionKey) }

  private static func boolDefaultingTrue(_ key: String) -> Bool {
    UserDefaults.standard.object(forKey: key) == nil
      ? true : UserDefaults.standard.bool(forKey: key)
  }
}
