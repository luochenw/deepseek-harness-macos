import SwiftUI

/// Composer microphone button (V1 push-to-talk): tap to start listening, tap
/// again — or ~1.2s of silence — to finalize; the transcript is handed to
/// `onCommit`. While listening the button pulses and a compact bubble shows
/// the live partial transcript. When the host passes `speakReplies`, a small
/// speaker toggle controls automatic reply playback.
///
/// V2: when the wake word is enabled (VoiceSettings.wakeEnabled, default off)
/// the button also hosts a resident WakeWordListener — an orange dot shows the
/// honest resident-mic state, hearing the phrase starts the same listening
/// flow as a click, and the context menu toggles the feature. The listener is
/// suspended for the whole talk session and resumed when it ends.
struct VoiceInputButton: View {
  var speakReplies: Binding<Bool>?
  var onCommit: (String) -> Void
  @StateObject private var voice = VoiceController()
  @StateObject private var wake = WakeWordListener()
  @State private var pulsing = false
  @State private var showDeniedHelp = false
  private var deniedMessage: String? {
    if case .denied(let message) = voice.state { return message }
    return nil
  }

  init(speakReplies: Binding<Bool>? = nil, onCommit: @escaping (String) -> Void) {
    self.speakReplies = speakReplies
    self.onCommit = onCommit
  }

  private var isActive: Bool { voice.state == .listening || voice.state == .transcribing }

  var body: some View {
    HStack(spacing: 6) {
      Button(action: toggle) {
        ZStack {
          if isActive {
            Circle()
              .stroke(Color.accentColor.opacity(0.55), lineWidth: 2)
              .scaleEffect(pulsing ? 1.7 : 0.9)
              .opacity(pulsing ? 0 : 1)
          }
          Circle().fill(isActive ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
          Image(systemName: iconName).font(.system(size: 13, weight: .medium)).foregroundStyle(iconColor)
        }
        .frame(width: 30, height: 30)
        .overlay(alignment: .topTrailing) {
          // Honest resident-mic indicator: shown iff the wake tap is running.
          if wake.isActive {
            Circle().fill(.orange).frame(width: 7, height: 7)
              .overlay(Circle().stroke(.background, lineWidth: 1))
              .offset(x: 1, y: -1)
          }
        }
      }
      .buttonStyle(.borderless)
      .help(helpText)
      // Denied/failed states get a visible, actionable explainer — a silent
      // grey button reads as "voice is broken". Note: an ad-hoc-signed app
      // loses its microphone/speech TCC grants on every reinstall, so users
      // may need to re-authorize after updates.
      .popover(isPresented: $showDeniedHelp, arrowEdge: .top) {
        VStack(alignment: .leading, spacing: 10) {
          Label("语音暂不可用", systemImage: "mic.slash").font(.headline)
          Text(deniedMessage ?? "请授权麦克风与语音识别后重试。").font(.caption)
          Text("提示：每次重新安装 app 后，系统会重新询问授权；如果没有弹出询问，请在系统设置中手动开启。").font(.caption2).foregroundStyle(.secondary)
          HStack {
            Button("打开「麦克风」设置") { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) } }
            Button("打开「语音识别」设置") { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") { NSWorkspace.shared.open(url) } }
          }.controlSize(.small)
          Button("重试") { showDeniedHelp = false; toggle() }.controlSize(.small)
        }
        .padding(14).frame(width: 320)
      }
      .contextMenu {
        if isActive { Button("取消聆听") { voice.cancelListening() } }
        Button("停止播报") { voice.stopSpeaking() }
        Divider()
        Button(VoiceSettings.wakeEnabled ? "停用唤醒词" : "启用唤醒词（\(VoiceSettings.wakePhrase)）") {
          UserDefaults.standard.set(!VoiceSettings.wakeEnabled, forKey: VoiceSettings.wakeEnabledKey)
          syncWakeListener()
        }
        if let note = wake.statusNote { Text(note) }
        if let note = voice.speechEngineNote { Text(note) }
      }
      if let speakReplies {
        Toggle(isOn: speakReplies) {
          Image(systemName: speakReplies.wrappedValue ? "speaker.wave.2.fill" : "speaker.slash")
        }
        .toggleStyle(.button)
        .help("自动播报回复")
      }
    }
    .overlay(alignment: .bottom) { transcriptBubble }
    .onAppear {
      voice.onFinalText = { text in onCommit(text) }
      syncWakeListener()
    }
    // Covers both the settings pane and the context menu writing the defaults.
    .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in syncWakeListener() }
    .onChange(of: voice.state) { _, newState in
      switch newState {
      case .idle, .denied: wake.resume() // talk session over; no-op unless suspended
      default: break
      }
    }
    .onChange(of: isActive) { _, active in
      if active {
        pulsing = false
        withAnimation(.easeOut(duration: 1.0).repeatForever(autoreverses: false)) { pulsing = true }
      } else {
        pulsing = false
      }
    }
  }

  @ViewBuilder private var transcriptBubble: some View {
    if isActive {
      VStack(alignment: .leading, spacing: 4) {
        Label(voice.state == .transcribing ? "正在识别…" : "正在聆听…", systemImage: "waveform")
          .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        if !voice.partialText.isEmpty { Text(voice.partialText).font(.caption).lineLimit(3) }
      }
      .padding(10)
      .frame(minWidth: 160, maxWidth: 280, alignment: .leading)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.2)))
      .fixedSize(horizontal: false, vertical: true)
      .offset(y: -44)
      .allowsHitTesting(false)
      .transition(.opacity)
    }
  }

  private var iconName: String {
    switch voice.state {
    case .listening, .transcribing: "mic.fill"
    case .denied: "mic.slash"
    default: "mic"
    }
  }

  private var iconColor: Color {
    switch voice.state {
    case .listening, .transcribing: .accentColor
    case .denied: .orange
    default: .secondary
    }
  }

  private var helpText: String {
    switch voice.state {
    case .idle: wake.isActive ? "按住说话（唤醒词监听中：说「\(VoiceSettings.wakePhrase)」开始）" : "按住说话"
    case .requestingPermission: "等待授权…"
    case .listening: "正在聆听…"
    case .transcribing: "正在识别…"
    case .denied(let message): "授权后可用：\(message)"
    }
  }

  /// Reconcile the resident listener with the wakeEnabled default; idempotent.
  private func syncWakeListener() {
    if VoiceSettings.wakeEnabled {
      wake.onWake = {
        voice.onFinalText = { text in onCommit(text) }
        voice.startListening()
      }
      wake.start()
    } else {
      wake.stop()
    }
  }

  private func toggle() {
    voice.onFinalText = { text in onCommit(text) }
    switch voice.state {
    case .listening: voice.stopListening()
    case .transcribing, .requestingPermission: break
    case .idle:
      wake.suspend() // free the shared recognizer/mic before the talk session
      voice.startListening()
    case .denied:
      // Second tap on a denied mic explains itself instead of failing again.
      showDeniedHelp = true
      wake.suspend()
      voice.startListening()
    }
  }
}
