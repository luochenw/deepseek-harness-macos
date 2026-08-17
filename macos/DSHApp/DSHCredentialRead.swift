import Foundation

/// 设置页回显：让"当前配置"可见 —— 见 api-settings-visible-values Agent Note。
/// 协议层的 credentials 服务有意只报告 configured 布尔（写单向）；App 与
/// Host 同机同用户，凭据值直接从 Host 配置根的 .credentials.yaml 本地读回，
/// 仅用于预填密码样式的输入框。
extension HarnessController {
  /// 平面 `KEY: value` 行级解析（Host 当前的写入格式；引号包裹会剥掉）。
  func credentialValue(ref: String) -> String? {
    let file = dshHome.appendingPathComponent(".credentials.yaml")
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
    for rawLine in text.split(separator: "\n") {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { continue }
      guard String(line[..<colon]).trimmingCharacters(in: .whitespaces) == ref else { continue }
      var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
      if value.count >= 2,
         (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
        value = String(value.dropFirst().dropLast())
      }
      return value.isEmpty ? nil : value
    }
    return nil
  }

  /// 自定义配置的当前档案值（API 地址/协议/模型），与编辑抽屉同源。
  func providerProfile(_ provider: DSHConfigurableProvider) -> [String: DSHJSONValue]? {
    settingsDescription?.namespaces.first(where: { $0.ns == provider.settingsNs })?
      .value.objectValue(at: provider.settingsPath)
  }
}
