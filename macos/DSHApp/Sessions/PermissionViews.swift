import SwiftUI

private struct PendingPermissionSelection {
  let value: String
  let sessionID: String?
}

struct PermissionMenu: View {
  @EnvironmentObject private var harness: HarnessController
  @State private var pendingFullAccess: PendingPermissionSelection?

  var body: some View {
    if harness.permissionMenuAvailable {
      Menu {
        ForEach(harness.permissionMenuOptions) { option in
          Button {
            choose(option)
          } label: {
            if option.value == harness.displayedPermissionSelection?.currentValue {
              Label(option.nativeLabel, systemImage: "checkmark")
            } else {
              Text(option.nativeLabel)
            }
          }
          .help(option.nativeDetail)
        }
      } label: {
        Label(harness.activePermissionLabel, systemImage: "lock.shield")
          .font(.system(size: 10.5))
          .foregroundStyle(
            harness.displayedPermissionSelection?.currentValue == "danger-full-access"
              ? DSHTheme.warm : DSHTheme.inkFaint)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .disabled(harness.permissionMenuBusy)
      .help("访问模式，当前：\(harness.activePermissionLabel)")
      .confirmationDialog(
        "启用完全访问？",
        isPresented: Binding(
          get: { pendingFullAccess != nil },
          set: { if !$0 { pendingFullAccess = nil } }),
        titleVisibility: .visible
      ) {
        Button("启用完全访问", role: .destructive) {
          guard let pending = pendingFullAccess else { return }
          pendingFullAccess = nil
          harness.selectPermission(pending.value, sessionID: pending.sessionID)
        }
        Button("取消", role: .cancel) { pendingFullAccess = nil }
      } message: {
        Text("完全访问会关闭文件沙箱和审批提示。仅在你信任当前任务时启用。")
      }
    }
  }

  private func choose(_ option: DSHPermissionOption) {
    let sessionID = harness.hostCurrentSessionID
    if option.requiresConfirmation {
      pendingFullAccess = PendingPermissionSelection(value: option.value, sessionID: sessionID)
    } else {
      harness.selectPermission(option.value, sessionID: sessionID)
    }
  }
}

struct PermissionDefaultSettingsRow: View {
  @EnvironmentObject private var harness: HarnessController
  @State private var pendingFullAccess: String?

  var body: some View {
    HStack(alignment: .center, spacing: DSHSpace.s3) {
      VStack(alignment: .leading, spacing: 2) {
        Text("新会话默认权限").font(.system(size: 13)).foregroundStyle(DSHTheme.ink)
        Text("只影响之后创建的会话；当前会话可在输入框底部单独切换。")
          .font(.system(size: 11)).foregroundStyle(DSHTheme.inkFaint)
      }
      Spacer(minLength: DSHSpace.s3)
      if let selection = harness.defaultPermissionSelection {
        Menu {
          ForEach(selection.options.filter(\.isSelectable)) { option in
            Button {
              if option.requiresConfirmation { pendingFullAccess = option.value }
              else { harness.setDefaultPermission(option.value) }
            } label: {
              if option.value == selection.currentValue {
                Label(option.nativeLabel, systemImage: "checkmark")
              } else {
                Text(option.nativeLabel)
              }
            }
          }
        } label: {
          Text(selection.currentOption?.nativeLabel ?? "访问模式")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(harness.settingsDescription?.writable != true || harness.permissionSettingsMutationInFlight)
      } else {
        Text("Host 未提供").font(.caption).foregroundStyle(DSHTheme.inkFaint)
      }
    }
    .confirmationDialog(
      "启用完全访问？",
      isPresented: Binding(
        get: { pendingFullAccess != nil },
        set: { if !$0 { pendingFullAccess = nil } }),
      titleVisibility: .visible
    ) {
      Button("启用完全访问", role: .destructive) {
        guard let value = pendingFullAccess else { return }
        pendingFullAccess = nil
        harness.setDefaultPermission(value)
      }
      Button("取消", role: .cancel) { pendingFullAccess = nil }
    } message: {
      Text("之后创建的会话将不受文件沙箱限制，也不会弹出审批请求。")
    }
  }
}

struct BusyEnterSettingsRow: View {
  @EnvironmentObject private var harness: HarnessController

  var body: some View {
    HStack(alignment: .center, spacing: DSHSpace.s3) {
      VStack(alignment: .leading, spacing: 2) {
        Text("运行中按回车").font(.system(size: 13)).foregroundStyle(DSHTheme.ink)
        Text("回车发送开启时，Command+回车执行另一种方式；关闭时，Command+回车使用此方式。")
          .font(.system(size: 11)).foregroundStyle(DSHTheme.inkFaint)
      }
      Spacer(minLength: DSHSpace.s3)
      if harness.busyEnterSettingsNamespace != nil {
        Menu {
          ForEach([DSHPromptMode.queue, .steer]) { mode in
            Button {
              harness.setBusyEnterMode(mode)
            } label: {
              if mode == harness.busyEnterMode {
                Label(mode.nativeLabel, systemImage: "checkmark")
              } else {
                Text(mode.nativeLabel)
              }
            }
          }
        } label: {
          Text(harness.busyEnterMode.nativeLabel)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(harness.settingsDescription?.writable != true || harness.busyEnterSettingsMutationInFlight)
      } else {
        Text("Host 未提供").font(.caption).foregroundStyle(DSHTheme.inkFaint)
      }
    }
  }
}
