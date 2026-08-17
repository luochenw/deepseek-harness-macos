import SwiftUI

/// Voice settings pane (V2 wake word + V3 engine/endpoints). Bound directly to
/// UserDefaults via @AppStorage — the same keys VoiceSettings (DSHVoice.swift)
/// reads; VoiceInputButton reconciles the resident listener on defaults
/// changes, and engine selection takes effect on the next utterance. These are
/// per-machine client preferences, so they live outside the Host's revisioned
/// settings namespaces.
struct VoiceSettingsView: View {
  @AppStorage(VoiceSettings.wakeEnabledKey) private var wakeEnabled = false
  @AppStorage(VoiceSettings.wakeAutoEnableKey) private var wakeAutoEnable = true
  @AppStorage(VoiceSettings.wakeAutoSendKey) private var wakeAutoSend = true
  @AppStorage(VoiceSettings.wakePhraseKey) private var wakePhrase = VoiceSettings.defaultWakePhrase
  @AppStorage(VoiceSettings.engineKey) private var engine = "apple"
  @AppStorage(VoiceSettings.sttEndpointKey) private var sttEndpoint = ""
  @AppStorage(VoiceSettings.ttsEndpointKey) private var ttsEndpoint = ""

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s4) {
      VStack(alignment: .leading, spacing: DSHSpace.s2) {
        Text("唤醒词").dshSectionLabel()
        Toggle("启用唤醒词（麦克风常驻监听）", isOn: $wakeEnabled).foregroundStyle(DSHTheme.ink)
        Toggle("首次使用麦克风后自动开启唤醒词", isOn: $wakeAutoEnable).foregroundStyle(DSHTheme.ink)
        Toggle("唤醒识别的内容自动发送", isOn: $wakeAutoSend).foregroundStyle(DSHTheme.ink)
        TextField("唤醒短语", text: $wakePhrase, prompt: Text(VoiceSettings.defaultWakePhrase))
          .dshField()
        Text("常驻监听只用系统离线中文识别，音频不出本机；监听中麦克风按钮显示橙色圆点。点击麦克风的手动听写只把文字填进输入框、从不自动发送；唤醒词听写默认自动发送，可用上方开关关闭。手动关闭唤醒词后不会再被自动开启。")
          .font(.caption).foregroundStyle(DSHTheme.inkFaint).fixedSize(horizontal: false, vertical: true)
      }
      .padding(DSHSpace.s3).dshCard(tint: DSHTheme.surfaceTint, radius: DSHRadius.md)

      VStack(alignment: .leading, spacing: DSHSpace.s2) {
        Text("识别与合成引擎").dshSectionLabel()
        Picker("语音引擎", selection: $engine) {
          Text("Apple 本地（零配置）").tag("apple")
          Text("自建端点（whisper.cpp / 本地 TTS）").tag("local")
        }
        .pickerStyle(.radioGroup)
        .foregroundStyle(DSHTheme.ink)
        TextField("识别端点（STT）", text: $sttEndpoint, prompt: Text("http://127.0.0.1:8080/inference"))
          .dshField().disabled(engine != "local")
        TextField("合成端点（TTS）", text: $ttsEndpoint, prompt: Text("http://127.0.0.1:8081/tts"))
          .dshField().disabled(engine != "local")
        Text("STT 按 whisper.cpp server 约定：整段录音以 WAV（16kHz 单声道）作为 multipart 的 file 字段 POST 到端点（只填主机端口时自动补 /inference 路径），读取响应 JSON 的 text 字段；本地引擎无流式中间结果，说完再点一次麦克风结束。TTS 端点接收 JSON {\"text\": …}，返回 wav/mp3 音频字节。端点留空或请求失败时自动回退 Apple 本地引擎（TTS 回退会在麦克风右键菜单注明）。引擎切换自下一次说话起生效。")
          .font(.caption).foregroundStyle(DSHTheme.inkFaint).fixedSize(horizontal: false, vertical: true)
      }
      .padding(DSHSpace.s3).dshCard(tint: DSHTheme.surfaceTint, radius: DSHRadius.md)
    }
  }
}
