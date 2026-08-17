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
  @AppStorage(VoiceSettings.silenceEndpointKey) private var silenceSeconds = 2.0
  @AppStorage(VoiceSettings.engineKey) private var engine = "apple"
  @AppStorage(VoiceSettings.sttEndpointKey) private var sttEndpoint = ""
  @AppStorage(VoiceSettings.ttsEndpointKey) private var ttsEndpoint = ""

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s4) {
      DSHSettingsGroup(title: "唤醒词") {
        DSHToggleRow(
          title: "启用唤醒词",
          caption: "麦克风常驻监听；只用系统离线中文识别，音频不出本机。监听中麦克风按钮显示橙色圆点。",
          isOn: $wakeEnabled)
        DSHToggleRow(
          title: "首次使用麦克风后自动开启唤醒词",
          caption: "手动关闭唤醒词后不会再被自动开启。",
          isOn: $wakeAutoEnable)
        DSHToggleRow(
          title: "唤醒识别的内容自动发送",
          caption: "开启时唤醒任务派发到独立后台会话执行；关闭则只填进输入框。手动点麦克风的听写从不自动发送。",
          isOn: $wakeAutoSend)
        HStack(spacing: DSHSpace.s3) {
          Text("唤醒短语").font(.system(size: 13)).foregroundStyle(DSHTheme.ink)
          Spacer(minLength: DSHSpace.s3)
          TextField("", text: $wakePhrase, prompt: Text(VoiceSettings.defaultWakePhrase))
            .dshField().frame(width: 180)
        }
        HStack(spacing: DSHSpace.s3) {
          VStack(alignment: .leading, spacing: 2) {
            Text("停顿 \(silenceSeconds, specifier: "%.1f") 秒后自动定稿")
              .font(.system(size: 13)).foregroundStyle(DSHTheme.ink)
            Text("语音指令：说「结束 / 发送 / 就这样」立即定稿；整句只说「取消 / 不需要 / 算了」则整段放弃。")
              .font(.system(size: 11)).foregroundStyle(DSHTheme.inkFaint)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: DSHSpace.s3)
          Stepper("", value: $silenceSeconds, in: 1.0...10.0, step: 0.5)
            .labelsHidden()
        }
        Button("打开系统「听写」设置", action: VoiceSettings.openDictationSettings)
          .buttonStyle(.dshSecondary)
          .help("唤醒词依赖 macOS 系统听写（本地识别）；未开启时常驻监听无法运行")
      }

      DSHSettingsGroup(title: "识别与合成引擎") {
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
          .font(.system(size: 11)).foregroundStyle(DSHTheme.inkFaint).fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
