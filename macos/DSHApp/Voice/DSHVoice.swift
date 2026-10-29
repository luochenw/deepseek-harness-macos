import AppKit

/// 语音链路诊断：NSLog 在统一日志里检索不可靠，落文件最稳
/// （~/Library/Application Support/DeepSeek Harness/dsh/voice-diag.log）。
func voiceDiag(_ line: String) {
  let dir = ProcessInfo.processInfo.environment["DSH_APP_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/DeepSeek Harness/dsh", isDirectory: true)
  let url = dir.appendingPathComponent("voice-diag.log")
  let stamp = ISO8601DateFormatter().string(from: Date())
  guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
  if let handle = try? FileHandle(forWritingTo: url) {
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: data)
  } else {
    try? data.write(to: url)
  }
}
import AVFoundation
import Foundation
import Speech

// Voice input/output engine for V1 push-to-talk (see Agent Note
// 2026-08-15-voice-assistant-wake-word.md). Self-contained: no
// HarnessController dependency; the hosting view wires transcripts into the
// composer via VoiceController.onFinalText.

// MARK: - Engine seams (V3 local-server implementations plug in here)

/// Streaming speech-to-text engine. Default implementation is Apple's
/// SFSpeechRecognizer (on-device when the local zh_CN model is installed);
/// V3 adds a local-server engine (whisper.cpp / FunASR) behind this protocol.
protocol VoiceTranscriber: AnyObject {
  /// Growing partial transcript. Implementations deliver on the main queue.
  var onPartialText: ((String) -> Void)? { get set }
  /// Final transcript, delivered exactly once per streaming session on the
  /// main queue (best-effort partial if the recognizer errors out).
  var onFinalText: ((String) -> Void)? { get set }
  /// Human-readable engine mode note for status display (on-device vs. server fallback).
  var engineNote: String { get }
  func startStreaming() throws
  /// Stop capturing audio and finalize; onFinalText fires with the result.
  func finishStreaming()
  /// Hard-stop and discard the session; no further callbacks fire.
  func cancelStreaming()
}

/// Text-to-speech engine. Default is AVSpeechSynthesizer; V3 adds a
/// local-server engine (GPT-SoVITS / Kokoro) behind this protocol.
protocol VoiceSpeechSynthesizer: AnyObject {
  func speak(_ text: String)
  func stopSpeaking()
}

enum VoiceEngineError: LocalizedError {
  case recognizerUnavailable
  case audioFormatUnavailable
  var errorDescription: String? {
    switch self {
    case .recognizerUnavailable: "中文语音识别当前不可用（系统语音服务未就绪）"
    case .audioFormatUnavailable: "无法配置录音格式（未检测到可用的音频输入）"
    }
  }
}

// MARK: - Audio tap gate (exception-free install path)

/// Decides whether a tap can be installed on bus 0 before AVAudioEngine is touched.
enum VoiceTapGate {
  struct Plan: Equatable {
    let sampleRate: Double
    let channels: Int
    let bufferSize: Int
  }

  enum Decision: Equatable {
    case install(Plan)
    case skip(String)
  }

  static let sampleRateRange: ClosedRange<Double> = 8_000...192_000
  static let channelRange: ClosedRange<Int> = 1...8
  /// AVAudioNode.h documents a 100–400 ms tap buffer.
  static let bufferMillisecondsRange: ClosedRange<Int> = 100...400

  static func formatIsUsable(sampleRate: Double, channels: Int) -> Bool {
    sampleRate.isFinite
      && sampleRateRange.contains(sampleRate)
      && channelRange.contains(channels)
  }

  static func frames(forMilliseconds ms: Int, sampleRate: Double) -> Int {
    let clamped = min(max(ms, bufferMillisecondsRange.lowerBound), bufferMillisecondsRange.upperBound)
    guard sampleRate.isFinite, sampleRate > 0 else { return clamped }
    let raw = sampleRate * Double(clamped) / 1000
    guard raw.isFinite, raw > 0, raw < Double(Int.max / 2) else { return clamped }
    return max(1, Int(raw.rounded()))
  }

  static func milliseconds(forFrames frames: Int, sampleRate: Double) -> Int {
    guard sampleRate.isFinite, sampleRate > 0, frames > 0 else {
      return bufferMillisecondsRange.lowerBound
    }
    let raw = Double(frames) / sampleRate * 1000
    guard raw.isFinite, raw < Double(Int.max / 2) else { return bufferMillisecondsRange.upperBound }
    return Int(raw.rounded())
  }

  /// Formats a sample rate without an integer conversion (Int(NaN) traps).
  static func describeSampleRate(_ sampleRate: Double) -> String {
    sampleRate.isFinite ? String(format: "%.0f", sampleRate) : "\(sampleRate)"
  }

  static func decide(sampleRate: Double, channels: Int, engineIsRunning: Bool, bufferSize: Int) -> Decision {
    _ = engineIsRunning
    guard formatIsUsable(sampleRate: sampleRate, channels: channels) else {
      return .skip("音频输入格式不可用（\(describeSampleRate(sampleRate))Hz / \(channels) 声道）")
    }
    let frames = frames(
      forMilliseconds: milliseconds(forFrames: bufferSize, sampleRate: sampleRate),
      sampleRate: sampleRate)
    return .install(Plan(sampleRate: sampleRate, channels: channels, bufferSize: frames))
  }

  /// Backoff from the failure streak, so a broken listener cannot reinstall on a fixed cadence.
  static func restartDelay(failures: Int, base: TimeInterval, cap: TimeInterval) -> TimeInterval {
    guard failures > 0 else { return base }
    if failures >= 8 { return cap }
    return min(base * pow(2, Double(failures)), cap)
  }
}

func voiceInputDeviceAvailable() -> Bool {
  var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultInputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  var deviceID = AudioDeviceID(0)
  var size = UInt32(MemoryLayout<AudioDeviceID>.size)
  let status = AudioObjectGetPropertyData(
    AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
  return status == noErr && deviceID != 0
}

func voiceInputFormat(_ engine: AVAudioEngine) -> AVAudioFormat? {
  guard voiceInputDeviceAvailable() else { return nil }
  return engine.inputNode.outputFormat(forBus: 0)
}

func removeVoiceTap(_ engine: AVAudioEngine, installed: Bool) {
  if engine.isRunning { engine.stop() }
  guard installed else { return }
  engine.inputNode.removeTap(onBus: 0)
}

@discardableResult
func installVoiceTap(
  _ engine: AVAudioEngine,
  bufferSize: Int,
  format suppliedFormat: AVAudioFormat? = nil,
  wasInstalled: Bool = false,
  onSkip: (String) -> Void,
  block: @escaping AVAudioNodeTapBlock
) -> Bool {
  let format: AVAudioFormat
  if let suppliedFormat {
    format = suppliedFormat
  } else if let read = voiceInputFormat(engine) {
    format = read
  } else {
    voiceDiag("[tap] skipped: no default input device")
    onSkip("未检测到音频输入设备")
    return false
  }
  switch VoiceTapGate.decide(
    sampleRate: format.sampleRate,
    channels: Int(format.channelCount),
    engineIsRunning: engine.isRunning,
    bufferSize: bufferSize
  ) {
  case .skip(let reason):
    voiceDiag("[tap] skipped: \(reason)")
    onSkip(reason)
    return false
  case .install(let plan):
    // A running engine with a tap still installed is exactly what raises: tear it down.
    removeVoiceTap(engine, installed: wasInstalled)
    let input = engine.inputNode
    input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(plan.bufferSize), format: format) { buffer, when in
      block(buffer, when)
    }
    return true
  }
}

// MARK: - User settings (UserDefaults-backed; edited in VoiceSettingsView)

/// Voice feature settings. Plain UserDefaults rather than the Host's revisioned
/// settings namespaces: these are per-machine client preferences (mic residency,
/// loopback endpoints) with no Host-side meaning.
enum VoiceSettings {
  static let wakeEnabledKey = "dsh.voice.wakeEnabled"
  /// Set the first time wake gets auto-enabled after a successful talk
  /// session — so an explicit later opt-out is never overridden again.
  static let wakeAutoEnabledOnceKey = "dsh.voice.wakeAutoEnabledOnce"
  /// Whether the first successful talk session auto-enables wake (default on).
  static let wakeAutoEnableKey = "dsh.voice.wakeAutoEnable"
  static var wakeAutoEnableOnFirstUse: Bool {
    UserDefaults.standard.object(forKey: wakeAutoEnableKey) == nil ? true : UserDefaults.standard.bool(forKey: wakeAutoEnableKey)
  }
  /// Whether a wake-word-initiated utterance auto-sends (default on); a
  /// manual mic click never auto-sends regardless.
  static let wakeAutoSendKey = "dsh.voice.wakeAutoSend"
  static var wakeAutoSend: Bool {
    UserDefaults.standard.object(forKey: wakeAutoSendKey) == nil ? true : UserDefaults.standard.bool(forKey: wakeAutoSendKey)
  }
  static let wakePhraseKey = "dsh.voice.wakePhrase"

  /// 唤醒任务的默认工作区路径（设置→语音）。空 = 跟随当前工作区；
  /// "~default~" = Host 默认目录；其余为已引入工作区的绝对路径。
  /// 话里点名的工作区永远优先于这里的设定。
  static let dispatchWorkspaceKey = "dsh.voice.dispatchWorkspace"
  static var dispatchWorkspacePath: String {
    UserDefaults.standard.string(forKey: dispatchWorkspaceKey) ?? ""
  }
  static let dispatchHostDefaultToken = "~default~"

  /// 静音自动定稿秒数（设置→语音；1–10s，默认 2s）。
  static let silenceEndpointKey = "dsh.voice.silenceEndpoint"
  static var silenceEndpoint: TimeInterval {
    let value = UserDefaults.standard.double(forKey: silenceEndpointKey)
    return (1.0...10.0).contains(value) ? value : 2.0
  }

  /// 定稿类指令：出现在句尾时立即结束聆听并定稿，命令词本身剔除。
  static let endPhrases = ["就这样", "结束", "发送"]
  /// 取消类指令：整段话就是一个"放弃"指令 —— 不进输入框、不发送。
  static let cancelPhrases = ["不需要开启对话", "不需要新建对话", "不需要", "不用了", "没事了", "没事", "算了", "取消"]

  /// Trailing end-phrase check on a partial/final transcript (normalized:
  /// whitespace/punctuation-insensitive, same rules as wake matching).
  static func strippingTrailingEndPhrase(_ text: String) -> (stripped: String, matched: Bool) {
    let normalized = normalizedForWakeMatch(text)
    for phrase in endPhrases {
      let normalizedPhrase = normalizedForWakeMatch(phrase)
      guard !normalizedPhrase.isEmpty, normalized.hasSuffix(normalizedPhrase) else { continue }
      // Strip from the RAW text: drop trailing punctuation/space, then the
      // phrase characters, then trailing separators again.
      var raw = Substring(text)
      while let last = raw.last, last.isWhitespace || last.isPunctuation { raw = raw.dropLast() }
      if raw.hasSuffix(phrase) { raw = raw.dropLast(phrase.count) }
      while let last = raw.last, last.isWhitespace || last.isPunctuation { raw = raw.dropLast() }
      return (String(raw), true)
    }
    return (text, false)
  }

  /// True when the whole utterance is nothing but a cancel command.
  static func isCancelCommand(_ text: String) -> Bool {
    let normalized = normalizedForWakeMatch(text)
    guard !normalized.isEmpty else { return false }
    return cancelPhrases.contains { normalizedForWakeMatch($0) == normalized }
  }

  /// Deep link straight to 系统设置 → 键盘（听写所在页）。
  static func openDictationSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Dictation") {
      NSWorkspace.shared.open(url)
    }
  }
  static let engineKey = "dsh.voice.engine" // "apple" (default) | "local"
  static let sttEndpointKey = "dsh.voice.sttEndpoint"
  static let ttsEndpointKey = "dsh.voice.ttsEndpoint"
  static let defaultWakePhrase = "小D小D"

  static var wakeEnabled: Bool { UserDefaults.standard.bool(forKey: wakeEnabledKey) }
  static var wakePhrase: String {
    guard let value = UserDefaults.standard.string(forKey: wakePhraseKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return defaultWakePhrase }
    return value
  }
  static var engine: String { UserDefaults.standard.string(forKey: engineKey) ?? "apple" }
  static var sttEndpointURL: URL? { endpointURL(forKey: sttEndpointKey) }
  static var ttsEndpointURL: URL? { endpointURL(forKey: ttsEndpointKey) }

  private static func endpointURL(forKey key: String) -> URL? {
    guard let raw = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
          let url = URL(string: raw), url.scheme == "http" || url.scheme == "https", url.host != nil else { return nil }
    return url
  }

  /// Loose normalization for wake-phrase matching: fullwidth→halfwidth,
  /// lowercase, and strip whitespace/punctuation/symbols so「小 d，小 d」
  /// matches「小D小D」. (Simplified/traditional folding deliberately skipped —
  /// zh_CN recognition output is simplified, matching the default phrase.)
  static func normalizedForWakeMatch(_ text: String) -> String {
    let folded = (text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text).lowercased()
    let dropped = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
    return String(String.UnicodeScalarView(folded.unicodeScalars.filter { !dropped.contains($0) }))
  }
}

// MARK: - Voice routing

/// 听写结果去向。在激活（唤醒命中 / 点击麦克风）那一刻快照到
/// VoiceController.sessionRoute，听写中途 app 状态变化不再翻转。
enum VoiceRoute: Equatable {
  /// 用户在对话框前（app 在最顶层）：进输入框，唤醒听写停止后自动发送到
  /// 当前会话（运行中则排队续接）。
  case dialog
  /// app 在后台：不进输入框，静默派发到独立后台会话执行。
  case background
}

enum VoiceCommitAction: Equatable {
  case fillComposer
  case submitCurrent
  case steerCurrent
  case queueCurrent
  case dispatchBackground
}

extension VoiceRoute {
  func commitAction(
    viaWake: Bool,
    autoSend: Bool,
    canSubmit: Bool,
    canSteer: Bool,
    canQueue: Bool
  ) -> VoiceCommitAction {
    guard viaWake, autoSend else { return .fillComposer }
    switch self {
    case .background:
      return .dispatchBackground
    case .dialog:
      if canSubmit { return .submitCurrent }
      if canSteer { return .steerCurrent }
      if canQueue { return .queueCurrent }
      return .fillComposer
    }
  }
}

/// 判定"是否在对话框前"：app 是当前活动（最顶层）应用，且 keyWindow 不是
/// 悬浮圈这类非激活面板（它们不会偷走激活，也不该算"在对话框前"）。
@MainActor
func computeVoiceRoute() -> VoiceRoute {
  guard NSApp.isActive else { return .background }
  guard let key = NSApp.keyWindow, !(key is NSPanel) else { return .background }
  return .dialog
}

/// dialog 路由听写开始时，请求主窗口 composer 输入框获得焦点——语音"落进"
/// 正在输入的位置。ComposerView 监听 requestID 变化，把焦点交给输入框。
@MainActor
final class VoiceFocusRequest: ObservableObject {
  static let shared = VoiceFocusRequest()
  @Published private(set) var requestID = 0
  func request() { requestID += 1 }
  private init() {}
}

// MARK: - Apple default engines

/// SFSpeechRecognizer + AVAudioEngine streaming transcriber (zh_CN).
/// Prefers fully on-device recognition; falls back to Apple's server when the
/// local Chinese model is not installed, and says so in `engineNote`.
final class AppleSpeechTranscriber: VoiceTranscriber {
  var onPartialText: ((String) -> Void)?
  var onFinalText: ((String) -> Void)?
  private(set) var engineNote = "本地识别"

  private let audioEngine = AVAudioEngine()
  private var recognizer: SFSpeechRecognizer?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var lastTranscript = ""
  /// 识别器在长停顿处会另起新段（bestTranscription 整个重置为新段），
  /// 旧段在这里累积，定稿 = 各段拼接——否则停顿 1 秒前面说的全丢。
  private var committedPrefix = ""
  private var finalized = false
  private var finalizeFallback: DispatchWorkItem?
  private var receivedAnyResult = false
  private var retriedOnline = false
  /// 诊断：确认音频是否真的流进了识别请求（空定稿的头号嫌疑是无声输入）。
  private var tapBufferCount = 0
  private var tapInstalled = false

  func startStreaming() throws {
    retriedOnline = false
    try startStreaming(forceOnline: false)
  }

  private func startStreaming(forceOnline: Bool) throws {
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh_CN")), recognizer.isAvailable else {
      throw VoiceEngineError.recognizerUnavailable
    }
    self.recognizer = recognizer
    lastTranscript = ""
    committedPrefix = ""
    finalized = false
    receivedAnyResult = false
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    if forceOnline {
      // The on-device task died instantly (local speech daemon in a bad
      // state); this retry goes through Apple's server so the utterance
      // still lands instead of the session flashing shut.
      request.requiresOnDeviceRecognition = false
      engineNote = "在线识别（本地识别启动失败，已自动回退）"
    } else if recognizer.supportsOnDeviceRecognition {
      request.requiresOnDeviceRecognition = true
      engineNote = "本地识别"
    } else {
      // The on-device zh_CN model is not present on this machine; degrade to
      // Apple's server recognition rather than failing outright.
      request.requiresOnDeviceRecognition = false
      engineNote = "在线识别（本机无离线中文模型）"
    }
    self.request = request
    voiceDiag("[stt] start mode=\(engineNote)")
    tapBufferCount = 0
    let installed = installVoiceTap(audioEngine, bufferSize: 1024, wasInstalled: tapInstalled, onSkip: { reason in
      voiceDiag("[stt] tap not installed: \(reason)")
    }) { [weak self] buffer, _ in
      request.append(buffer)
      guard let self else { return }
      self.tapBufferCount += 1
      if self.tapBufferCount == 1 || self.tapBufferCount == 100 {
        var peak: Float = 0
        if let data = buffer.floatChannelData?[0] {
          for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[i])) }
        }
        voiceDiag("[stt] buffer#\(self.tapBufferCount) peak=\(peak)")
      }
    }
    guard installed else {
      tapInstalled = false
      throw VoiceEngineError.audioFormatUnavailable
    }
    tapInstalled = true
    audioEngine.prepare()
    do { try audioEngine.start() } catch {
      removeVoiceTap(audioEngine, installed: tapInstalled)
      tapInstalled = false
      throw error
    }
    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      DispatchQueue.main.async {
        guard let self, !self.finalized, self.request === request else { return }
        if let result {
          self.receivedAnyResult = true
          let text = result.bestTranscription.formattedString
          voiceDiag("[stt] result isFinal=\(result.isFinal) text='\(String(text.prefix(40)))'")
          if !text.isEmpty {
            // 停顿后识别器另起新段：新文本既不延续旧段、也不是旧段的
            // 修订（修订只改尾部，前缀关系仍在），且明显更短 → 把旧段
            // 计入前缀累积，别让它丢。
            if !self.lastTranscript.isEmpty,
               !text.hasPrefix(self.lastTranscript), !self.lastTranscript.hasPrefix(text),
               text.count < self.lastTranscript.count {
              self.committedPrefix += self.lastTranscript
              voiceDiag("[stt] segment reset — committed '\(String(self.committedPrefix.suffix(40)))'")
            }
            self.lastTranscript = text
            self.onPartialText?(self.committedPrefix + text)
          }
          // 本地中文识别在 endAudio 后常回一个 text 为空的 isFinal 结果；
          // 空结果不覆盖非空累积（否则整句被抹成空，表现为"说完没反应"）。
          if result.isFinal { self.deliverFinal() }
        } else if let error {
          voiceDiag("[stt] task error (anyResult=\(self.receivedAnyResult) retried=\(self.retriedOnline)): \(error.localizedDescription)")
          if !self.receivedAnyResult, !self.retriedOnline, request.requiresOnDeviceRecognition {
            // Died before producing anything — one-shot online fallback.
            self.retriedOnline = true
            self.stopCapture()
            try? self.startStreaming(forceOnline: true)
            return
          }
          // Post-endAudio errors (e.g. "no speech detected") still carry the
          // best partial we accumulated; deliver it instead of dropping the utterance.
          self.deliverFinal()
        }
      }
    }
  }

  func finishStreaming() {
    stopCapture()
    request?.endAudio()
    // Safety net: if the recognizer never reports a final result, deliver the
    // last partial after a short grace period.
    let fallback = DispatchWorkItem { [weak self] in self?.deliverFinal() }
    finalizeFallback?.cancel()
    finalizeFallback = fallback
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: fallback)
  }

  func cancelStreaming() {
    finalized = true
    stopCapture()
    request?.endAudio()
    task?.cancel()
    cleanup()
  }

  private func stopCapture() {
    removeVoiceTap(audioEngine, installed: tapInstalled)
    tapInstalled = false
  }

  /// Main-queue only (recognition callback and finalize fallback both hop there).
  private func deliverFinal() {
    guard !finalized else { return }
    finalized = true
    let text = committedPrefix + lastTranscript
    cleanup()
    onFinalText?(text)
  }

  private func cleanup() {
    finalizeFallback?.cancel()
    finalizeFallback = nil
    task = nil
    request = nil
  }
}

/// AVSpeechSynthesizer-backed Chinese TTS.
final class AppleSpeechSynthesizer: VoiceSpeechSynthesizer {
  private let synthesizer = AVSpeechSynthesizer()
  func speak(_ text: String) {
    if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
    synthesizer.speak(utterance)
  }
  func stopSpeaking() { synthesizer.stopSpeaking(at: .immediate) }
}

// MARK: - V3 local-server engines

/// Local-server speech-to-text (whisper.cpp server convention): accumulates
/// 16kHz mono PCM while streaming, then POSTs the whole utterance as a WAV in
/// the multipart "file" field of `POST /inference` and reads the JSON `{text}`
/// response. No streaming partials — a placeholder partial is emitted when
/// inference starts so the UI shows progress; there is likewise no
/// partial-driven silence endpoint, so the utterance ends on the second tap.
final class LocalServerTranscriber: NSObject, VoiceTranscriber {
  var onPartialText: ((String) -> Void)?
  var onFinalText: ((String) -> Void)?
  private(set) var engineNote: String

  private let endpoint: URL
  private let audioEngine = AVAudioEngine()
  private let sampleLock = NSLock()
  private var pcmSamples = Data()
  private var uploadTask: URLSessionDataTask?
  private var finalized = false
  private var tapInstalled = false
  private static let targetSampleRate: Double = 16000

  init(endpoint: URL) {
    self.endpoint = endpoint
    self.engineNote = "本地端点识别（\(endpoint.host ?? endpoint.absoluteString)）"
  }

  func startStreaming() throws {
    finalized = false
    sampleLock.lock(); pcmSamples = Data(); sampleLock.unlock()
    guard let format = voiceInputFormat(audioEngine),
          let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.targetSampleRate, channels: 1, interleaved: true),
          let converter = AVAudioConverter(from: format, to: target) else {
      throw VoiceEngineError.audioFormatUnavailable
    }
    // Reuse the format just read: a second read could see a different device.
    let installed = installVoiceTap(audioEngine, bufferSize: 2048, format: format, wasInstalled: tapInstalled, onSkip: { reason in
      voiceDiag("[stt-local] tap not installed: \(reason)")
    }) { [weak self] buffer, _ in
      self?.appendSamples(from: buffer, using: converter, target: target)
    }
    guard installed else {
      tapInstalled = false
      throw VoiceEngineError.audioFormatUnavailable
    }
    tapInstalled = true
    audioEngine.prepare()
    do { try audioEngine.start() } catch {
      removeVoiceTap(audioEngine, installed: tapInstalled)
      tapInstalled = false
      throw error
    }
  }

  func finishStreaming() {
    guard !finalized else { return }
    stopCapture()
    onPartialText?("（本地模型识别中…）")
    sampleLock.lock(); let pcm = pcmSamples; pcmSamples = Data(); sampleLock.unlock()
    guard !pcm.isEmpty else { deliverFinal(""); return }
    upload(Self.wavFile(fromPCM16: pcm, sampleRate: Int(Self.targetSampleRate), channels: 1))
  }

  func cancelStreaming() {
    finalized = true
    stopCapture()
    uploadTask?.cancel()
    uploadTask = nil
    sampleLock.lock(); pcmSamples = Data(); sampleLock.unlock()
  }

  private func stopCapture() {
    removeVoiceTap(audioEngine, installed: tapInstalled)
    tapInstalled = false
  }

  /// Audio-thread tap: rate-convert this buffer to 16kHz mono Int16 and append.
  private func appendSamples(from buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, target: AVAudioFormat) {
    let ratio = target.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 32)
    guard capacity > 0, let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
    var fed = false
    var conversionError: NSError?
    converter.convert(to: converted, error: &conversionError) { _, outStatus in
      if fed { outStatus.pointee = .noDataNow; return nil }
      fed = true
      outStatus.pointee = .haveData
      return buffer
    }
    guard conversionError == nil, converted.frameLength > 0 else { return }
    let audioBuffer = converted.audioBufferList.pointee.mBuffers
    guard let base = audioBuffer.mData else { return }
    let byteCount = min(Int(converted.frameLength) * MemoryLayout<Int16>.size, Int(audioBuffer.mDataByteSize))
    let data = Data(bytes: base, count: byteCount)
    sampleLock.lock(); pcmSamples.append(data); sampleLock.unlock()
  }

  private func upload(_ wav: Data) {
    var request = URLRequest(url: Self.inferenceURL(for: endpoint))
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    let boundary = "dsh-voice-\(UUID().uuidString)"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    var body = Data()
    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"utterance.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
    body.append(wav)
    body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n--\(boundary)--\r\n".utf8))
    request.httpBody = body
    let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      DispatchQueue.main.async {
        guard let self, !self.finalized else { return }
        if let error {
          self.engineNote = "本地端点识别失败：\(error.localizedDescription)"
          self.deliverFinal("")
          return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status), let data else {
          self.engineNote = "本地端点识别失败：HTTP \(status)"
          self.deliverFinal("")
          return
        }
        guard let text = Self.transcriptText(fromServerResponse: data) else {
          self.engineNote = "本地端点响应无法解析（期望 JSON {text}）"
          self.deliverFinal("")
          return
        }
        self.deliverFinal(text)
      }
    }
    uploadTask = task
    task.resume()
  }

  /// Main-queue only; delivers the final transcript exactly once.
  private func deliverFinal(_ text: String) {
    guard !finalized else { return }
    finalized = true
    uploadTask = nil
    onFinalText?(text)
  }

  /// whisper.cpp server's inference route. A bare origin (no path) gets the
  /// conventional `/inference` appended; any explicit path is used verbatim.
  static func inferenceURL(for endpoint: URL) -> URL {
    let path = endpoint.path
    guard path.isEmpty || path == "/" else { return endpoint }
    return endpoint.appendingPathComponent("inference")
  }

  static func transcriptText(fromServerResponse data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let text = object["text"] as? String else { return nil }
    return text
  }

  /// Minimal RIFF/WAVE wrapper around raw 16-bit little-endian PCM.
  static func wavFile(fromPCM16 pcm: Data, sampleRate: Int, channels: Int) -> Data {
    var data = Data()
    func append(_ tag: String) { data.append(Data(tag.utf8)) }
    func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    append("RIFF"); append32(UInt32(36 + pcm.count)); append("WAVE")
    append("fmt "); append32(16); append16(1) // PCM
    append16(UInt16(channels)); append32(UInt32(sampleRate))
    append32(UInt32(sampleRate * channels * 2)); append16(UInt16(channels * 2)); append16(16)
    append("data"); append32(UInt32(pcm.count)); data.append(pcm)
    return data
  }
}

/// Local-server text-to-speech: POSTs JSON `{"text": …}` to the configured
/// endpoint and plays the returned audio bytes (wav/mp3) with AVAudioPlayer.
/// Any failure falls back to AppleSpeechSynthesizer, reported via `onStatus`.
final class LocalServerSynthesizer: NSObject, VoiceSpeechSynthesizer {
  /// Main-queue status note for display (fallback reason); nil clears it.
  var onStatus: ((String?) -> Void)?

  private let endpoint: URL
  private let fallback = AppleSpeechSynthesizer()
  private var player: AVAudioPlayer?
  private var fetchTask: URLSessionDataTask?
  /// Bumped on every speak/stop so stale completion handlers no-op.
  private var generation = 0

  init(endpoint: URL) { self.endpoint = endpoint }

  func speak(_ text: String) {
    stopSpeaking()
    generation += 1
    let expected = generation
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 60
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
    let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      DispatchQueue.main.async {
        guard let self, self.generation == expected else { return }
        self.fetchTask = nil
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard error == nil, (200..<300).contains(status), let data, !data.isEmpty else {
          self.fallBack(text, reason: error?.localizedDescription ?? "HTTP \(status)")
          return
        }
        do {
          let player = try AVAudioPlayer(data: data)
          self.player = player
          player.play()
          self.onStatus?(nil)
        } catch {
          self.fallBack(text, reason: "音频解码失败：\(error.localizedDescription)")
        }
      }
    }
    fetchTask = task
    task.resume()
  }

  func stopSpeaking() {
    generation += 1
    fetchTask?.cancel()
    fetchTask = nil
    player?.stop()
    player = nil
    fallback.stopSpeaking()
  }

  private func fallBack(_ text: String, reason: String) {
    onStatus?("本地 TTS 端点失败（\(reason)），已回退系统语音")
    fallback.speak(text)
  }
}

// MARK: - Controller

struct VoicePermissionGrant {
  let speech: Bool
  let microphone: Bool
  var isGranted: Bool { speech && microphone }
}

/// TCC requests can originate from a manual dictation controller, the resident
/// wake listener, and multiple restored windows. Coalesce them so the OS sees
/// at most one request operation while authorization is still undetermined.
actor VoicePermissionCoordinator {
  static let shared = VoicePermissionCoordinator()

  private var inFlight: Task<VoicePermissionGrant, Never>?

  func request() async -> VoicePermissionGrant {
    if let inFlight {
      return await inFlight.value
    }
    let task = Task { await Self.resolve() }
    inFlight = task
    let grant = await task.value
    inFlight = nil
    return grant
  }

  private static func resolve() async -> VoicePermissionGrant {
    let speech = await requestSpeech()
    let microphone = await requestMicrophone()
    return VoicePermissionGrant(speech: speech, microphone: microphone)
  }

  private static func requestSpeech() async -> Bool {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized:
      return true
    case .notDetermined:
      return await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { status in
          continuation.resume(returning: status == .authorized)
        }
      }
    default:
      return false
    }
  }

  private static func requestMicrophone() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return true
    case .notDetermined:
      return await AVCaptureDevice.requestAccess(for: .audio)
    default:
      return false
    }
  }
}

/// Push-to-talk voice controller: microphone streaming transcription with a
/// silence endpoint, plus spoken playback of assistant replies. Main-actor
/// confined; both engines deliver their callbacks on the main queue.
@MainActor
final class VoiceController: NSObject, ObservableObject {
  enum State: Equatable {
    case idle
    case requestingPermission
    case listening
    case transcribing
    case denied(String)
  }

  @Published private(set) var state: State = .idle
  @Published private(set) var partialText = ""
  /// TTS engine status for display (e.g. local-endpoint fallback reason).
  @Published private(set) var speechEngineNote: String?
  /// Set by the hosting view; receives the trimmed final transcript once per utterance.
  var onFinalText: ((String) -> Void)?
  /// Fires when an utterance ends WITHOUT usable text — cancel, no-speech
  /// timeout, or the transcript reduced to nothing after stripping command
  /// words. The hosting view uses it to restore the composer draft that
  /// live partials may have overwritten.
  var onDiscarded: (() -> Void)?
  /// Engine mode note for status display (on-device vs. server fallback).
  var engineNote: String { transcriber.engineNote }

  private var transcriber: VoiceTranscriber
  private var synthesizer: VoiceSpeechSynthesizer
  /// True when engines were injected (tests); settings never swap them then.
  private let enginesInjected: Bool
  private var synthesizerFingerprint: String
  private var silenceTimer: Timer?
  /// Auto endpoint: stop listening this long after the last new partial
  /// result — user-configurable (设置→语音), floor 1s so natural zh pauses
  /// don't truncate mid-sentence.
  private var silenceEndpoint: TimeInterval { VoiceSettings.silenceEndpoint }
  /// 完全没等到语音的最长等待：超时整段放弃并恢复输入框。比静音定稿窗口
  /// 长——热身空分段不算语音，真实语音一到就换成静音定稿计时。
  private let noSpeechWindow: TimeInterval = 5.0

  init(transcriber: VoiceTranscriber? = nil, synthesizer: VoiceSpeechSynthesizer? = nil) {
    self.enginesInjected = transcriber != nil || synthesizer != nil
    self.transcriber = transcriber ?? Self.makeTranscriber()
    self.synthesizer = synthesizer ?? Self.makeSynthesizer()
    self.synthesizerFingerprint = Self.currentSynthesizerFingerprint
    super.init()
    wireSynthesizerStatus()
  }

  // MARK: Engine selection (V3)

  /// "local" engine uses the configured HTTP endpoints; each endpoint falls
  /// back to the Apple engine independently when unset or invalid.
  static func makeTranscriber() -> VoiceTranscriber {
    guard VoiceSettings.engine == "local", let url = VoiceSettings.sttEndpointURL else { return AppleSpeechTranscriber() }
    return LocalServerTranscriber(endpoint: url)
  }

  static func makeSynthesizer() -> VoiceSpeechSynthesizer {
    guard VoiceSettings.engine == "local", let url = VoiceSettings.ttsEndpointURL else { return AppleSpeechSynthesizer() }
    return LocalServerSynthesizer(endpoint: url)
  }

  private static var currentSynthesizerFingerprint: String {
    guard VoiceSettings.engine == "local", let url = VoiceSettings.ttsEndpointURL else { return "apple" }
    return "local:\(url.absoluteString)"
  }

  /// Settings changes take effect on the next utterance: the transcriber is
  /// rebuilt per session, the synthesizer only when its config changed (so an
  /// in-flight playback is not cut by an unrelated new utterance).
  private func refreshEnginesFromSettings() {
    guard !enginesInjected else { return }
    transcriber = Self.makeTranscriber()
    let fingerprint = Self.currentSynthesizerFingerprint
    guard fingerprint != synthesizerFingerprint else { return }
    synthesizer.stopSpeaking()
    synthesizer = Self.makeSynthesizer()
    synthesizerFingerprint = fingerprint
    speechEngineNote = nil
    wireSynthesizerStatus()
  }

  private func wireSynthesizerStatus() {
    guard let local = synthesizer as? LocalServerSynthesizer else { return }
    local.onStatus = { [weak self] note in Task { @MainActor in self?.speechEngineNote = note } }
  }

  // MARK: Listening

  /// Whether the CURRENT talk session was started by the wake word — read
  /// by the commit path to decide auto-send. Lives here (reference type)
  /// rather than as view @State: a flag threaded through escaping closures
  /// on a struct proved unreliable, and the symptom was wake dictation
  /// filling the composer without sending.
  private(set) var sessionViaWake = false
  /// 本次听写会话的路由，startListening 调用瞬间快照（激活时刻）。
  private(set) var sessionRoute: VoiceRoute = .dialog

  func startListening(viaWake: Bool = false) {
    switch state {
    case .idle, .denied: break
    default: return
    }
    voiceDiag("[voice] startListening viaWake=\(viaWake)")
    sessionViaWake = viaWake
    // 路由在"激活瞬间"快照：唤醒词在 app 前台（对话框前）时进输入框、
    // 后台时派发；手动点麦克风必然在对话框前，恒为 dialog。dialog 路由
    // 顺手把输入框焦点要过来，让语音落进正在输入的位置。
    sessionRoute = viaWake ? computeVoiceRoute() : .dialog
    if sessionRoute == .dialog { VoiceFocusRequest.shared.request() }
    state = .requestingPermission
    Task { [weak self] in
      let permissions = await VoicePermissionCoordinator.shared.request()
      guard let self else { return }
      guard permissions.isGranted else {
        self.state = .denied("请在系统设置授权麦克风与语音识别")
        return
      }
      // 唤醒路径：常驻监听的音频引擎刚被拆掉，立刻抢启会拿到无声输入流
      // （识别器收不到任何结果，几秒后空定稿——表现为"说了没反应"）。
      // 给设备释放留一拍再启动。
      if viaWake {
        try? await Task.sleep(nanoseconds: 300_000_000)
      }
      self.beginStreaming()
    }
  }

  func stopListening() {
    guard state == .listening else { return }
    clearSilenceTimer()
    state = .transcribing
    transcriber.finishStreaming()
  }

  /// Discard the in-flight utterance without committing any text.
  func cancelListening() {
    switch state {
    case .listening, .transcribing: break
    default: return
    }
    voiceDiag("[voice] cancelListening state=\(state)")
    clearSilenceTimer()
    transcriber.cancelStreaming()
    partialText = ""
    state = .idle
    onDiscarded?()
  }

  // MARK: Speaking

  /// Speak assistant reply text: fenced code blocks are replaced with a short
  /// spoken placeholder and excess blank lines are collapsed before synthesis.
  func speak(_ text: String) {
    let script = Self.speechScript(from: text)
    guard !script.isEmpty else { return }
    synthesizer.speak(script)
  }

  func stopSpeaking() { synthesizer.stopSpeaking() }

  /// Markdown-to-speech preprocessing, exposed for testability.
  static func speechScript(from text: String) -> String {
    var script = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: "（一段代码）", options: .regularExpression)
    // Unterminated trailing fence (e.g. a reply cut mid-stream).
    script = script.replacingOccurrences(of: "```[\\s\\S]*", with: "（一段代码）", options: .regularExpression)
    script = script.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
    return script.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: Internals

  private func beginStreaming() {
    refreshEnginesFromSettings()
    partialText = ""
    transcriber.onPartialText = { [weak self] text in Task { @MainActor in self?.handlePartial(text) } }
    transcriber.onFinalText = { [weak self] text in Task { @MainActor in self?.handleFinal(text) } }
    do {
      try transcriber.startStreaming()
      state = .listening
      armNoSpeechTimer()
    } catch {
      state = .denied("语音识别启动失败：\(error.localizedDescription)")
    }
  }

  private func handlePartial(_ text: String) {
    switch state {
    case .listening:
      partialText = text
      // Only a real utterance arms the endpoint. The zh recognizer warms up
      // with empty partials, and arming on those closed the mic ~1.2s after
      // the click — before the user had said a word, which read as "语音
      // 输入完全不工作". Until speech arrives, the mic just keeps waiting.
      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { armSilenceTimer() }
      // 定稿类指令（"结束/发送/就这样"）出现在句尾 → 不等静音，立即定稿；
      // handleFinal 统一剔除命令词本身。
      if VoiceSettings.strippingTrailingEndPhrase(text).matched { stopListening() }
    case .transcribing:
      // Post-endAudio updates: late Apple partials, or the local engine's
      // "（本地模型识别中…）" placeholder. Display only — no silence timer.
      partialText = text
    default: break
    }
  }

  private func handleFinal(_ text: String) {
    clearSilenceTimer()
    switch state {
    case .listening, .transcribing: break
    default: return
    }
    state = .idle
    partialText = ""
    // 剔除句尾的定稿类命令词（"…结束" → "…"）。剔完为空（比如只说了
    // 一句"结束"）也必须通知宿主视图：实时分段可能已经把命令词流进了
    // 输入框，静默返回会把它留在那里。
    let stripped = VoiceSettings.strippingTrailingEndPhrase(text).stripped
    let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    voiceDiag("[voice] final raw='\(text)' stripped='\(trimmed)' viaWake=\(sessionViaWake)")
    guard !trimmed.isEmpty else { onDiscarded?(); return }
    onFinalText?(trimmed)
  }

  private func armSilenceTimer() {
    silenceTimer?.invalidate()
    silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceEndpoint, repeats: false) { [weak self] _ in
      Task { @MainActor in self?.stopListening() }
    }
  }

  /// Shares the silenceTimer slot: the first real utterance replaces this
  /// with the (much shorter) silence endpoint via armSilenceTimer.
  private func armNoSpeechTimer() {
    silenceTimer?.invalidate()
    silenceTimer = Timer.scheduledTimer(withTimeInterval: noSpeechWindow, repeats: false) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.state == .listening,
              self.partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        self.cancelListening()
      }
    }
  }

  private func clearSilenceTimer() {
    silenceTimer?.invalidate()
    silenceTimer = nil
  }

}

// MARK: - V2 wake word

/// Resident low-power wake-word listener: its own AVAudioEngine tap feeding a
/// streaming zh_CN SFSpeechRecognizer whose partial results are matched (with
/// loose normalization, over a sliding tail window) against the configurable
/// wake phrase. The recognition task is torn down and restarted every ~50s to
/// stay under SFSpeechRecognizer's single-task duration limit. On a hit it
/// suspends itself, then fires `onWake`; the host resumes it when the talk
/// session ends. Disabled by default (VoiceSettings.wakeEnabled).
@MainActor
final class WakeWordListener: NSObject, ObservableObject {
  static let shared = WakeWordListener()

  /// True while the microphone tap is actually running — the UI shows this so
  /// the resident-mic state is always honest.
  @Published private(set) var isActive = false
  /// Most recent start/permission failure, for display; nil when healthy.
  @Published private(set) var statusNote: String?
  /// True once failures are diagnosed as "系统听写未开启" — drives the
  /// mic button's proactive setup prompt (one-click jump to 系统设置).
  @Published private(set) var needsDictationSetup = false
  /// Fired on the main actor when the wake phrase is heard (listener is
  /// already suspended by then; call `resume()` after the talk session ends).
  var onWake: (() -> Void)?

  private let audioEngine = AVAudioEngine()
  private var recognizer: SFSpeechRecognizer?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var restartTimer: Timer?
  private var enabled = false // start() called, stop() not yet
  private var suspended = false // paused for an active talk session
  /// SFSpeechRecognizer caps a streaming task at ~1 minute; restart under it.
  private let taskRestartInterval: TimeInterval = 50
  private let errorRecoveryDelay: TimeInterval = 1.5
  /// Consecutive *real* failures (install / start / isRunning / task error).
  private var consecutiveFailures = 0
  /// Set while we tear a task down, so its own `cancel()` echo is not counted.
  private var isTearingDown = false
  /// Above this streak the listener stops rescheduling; the wake switch re-arms it.
  static let failureBreakerLimit = 5
  static let restartCap: TimeInterval = 300
  private var tapInstalled = false
  /// Injectable clock seam so the restart policy is testable without timers.
  var restartScheduler: (@MainActor (TimeInterval) -> Void)?

  private override init() {
    super.init()
  }

  /// Policy seam: delay before the next attempt, or nil once the breaker tripped.
  nonisolated static func nextRestartDelay(
    failures: Int,
    regularInterval: TimeInterval,
    failureBase: TimeInterval,
    cap: TimeInterval
  ) -> TimeInterval? {
    guard failures < failureBreakerLimit else { return nil }
    guard failures > 0 else { return regularInterval }
    return min(failureBase * pow(2, Double(failures)), cap)
  }

  func start() {
    guard !enabled else { return }
    enabled = true
    suspended = false
    // A manual toggle must genuinely re-arm, or only relaunching the app recovers.
    consecutiveFailures = 0
    Task { [weak self] in
      let permissions = await VoicePermissionCoordinator.shared.request()
      guard let self, self.enabled else { return }
      voiceDiag("[wake] start speech=\(permissions.speech) mic=\(permissions.microphone)")
      guard permissions.isGranted else {
        self.enabled = false
        self.statusNote = "唤醒词监听需要麦克风与语音识别权限"
        return
      }
      self.beginRecognition()
    }
  }

  func stop() {
    enabled = false
    suspended = false
    consecutiveFailures = 0
    tearDownRecognition()
    statusNote = nil
  }

  /// Pause the resident microphone for a talk session (a wake hit suspends
  /// automatically; manual push-to-talk should suspend before listening too,
  /// so two engines never contend for recognition at once).
  func suspend() {
    guard enabled, !suspended else { return }
    suspended = true
    tearDownRecognition()
  }

  /// Resume the resident microphone after the talk session ends.
  func resume() {
    guard enabled, suspended else { return }
    suspended = false
    beginRecognition()
  }

  private func beginRecognition() {
    tearDownRecognition()
    guard enabled, !suspended else { return }
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh_CN")), recognizer.isAvailable else {
      statusNote = "中文语音识别不可用，唤醒词监听未运行"
      recordFailure()
      scheduleRestart(regularInterval: nil)
      return
    }
    self.recognizer = recognizer
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    // Resident listening must stay local; without the on-device model, do not
    // stream the room's audio to Apple continuously.
    if recognizer.supportsOnDeviceRecognition {
      request.requiresOnDeviceRecognition = true
    } else {
      statusNote = "本机无离线中文模型，唤醒词监听未运行（不做常驻在线识别）"
      return
    }
    self.request = request
    let installed = installVoiceTap(audioEngine, bufferSize: 2048, onSkip: { [weak self] reason in
      // A stale tap or unusable format is what would raise inside AVAudioEngine.
      guard let self else { return }
      self.statusNote = "唤醒词监听未启动：\(reason)"
      voiceDiag("[wake] tap not installed: \(reason)")
    }) { buffer, _ in request.append(buffer) }
    guard installed else {
      // A transient failure must not strand the listener in a false "active" state.
      isActive = false
      tapInstalled = false
      recordFailure()
      statusNote = statusNote ?? "唤醒词监听未启动，稍后重试"
      scheduleRestart(regularInterval: nil)
      return
    }
    tapInstalled = true
    audioEngine.prepare()
    do { try audioEngine.start() } catch {
      isActive = false
      recordFailure()
      removeVoiceTap(audioEngine, installed: tapInstalled)
      tapInstalled = false
      statusNote = "唤醒词监听启动失败：\(error.localizedDescription)"
      scheduleRestart(regularInterval: nil)
      return
    }
    guard audioEngine.isRunning else {
      // Graph not live: leaving the tap installed makes the next install a double-install.
      isActive = false
      recordFailure()
      removeVoiceTap(audioEngine, installed: tapInstalled)
      tapInstalled = false
      statusNote = "唤醒词监听启动后引擎未运行，已清理并重试"
      scheduleRestart(regularInterval: nil)
      return
    }
    isActive = true
    statusNote = nil
    // Clear the streak: an earlier episode must not scale the 50 s rotation.
    consecutiveFailures = 0
    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      Task { @MainActor in
        guard let self, self.request === request else { return } // stale task
        if self.isTearingDown {
          // Our own endAudio()/cancel() produced this callback; counting it trips the breaker.
          voiceDiag("[wake] task error during teardown, ignored: \(error?.localizedDescription ?? "nil")")
          return
        }
        if let result {
          self.consecutiveFailures = 0
          self.handlePartial(result.bestTranscription.formattedString)
        } else if let error {
          // Breaker: a fixed 1.5 s retry restarted ~40×/min and killed manual talk sessions.
          self.recordFailure()
          self.tearDownRecognition()
          let reason = Self.friendlyFailureReason(error)
          if reason.contains("听写") { self.needsDictationSetup = true }
          if self.consecutiveFailures >= Self.failureBreakerLimit {
            self.statusNote = "唤醒词监听连续失败已暂停：\(reason)。重开唤醒词开关可重试。"
          } else {
            self.statusNote = "唤醒词监听重试中：\(reason)"
          }
          self.scheduleRestart(regularInterval: nil)
        }
      }
    }
    scheduleRestart(regularInterval: taskRestartInterval)
  }

  private func recordFailure() {
    consecutiveFailures += 1
  }

  private func handlePartial(_ transcript: String) {
    guard enabled, !suspended else { return }
    let phrase = VoiceSettings.normalizedForWakeMatch(VoiceSettings.wakePhrase)
    guard !phrase.isEmpty else { return }
    // Sliding window over the growing partial: only the recent tail can
    // trigger, so old chatter cannot re-match late in a long session.
    let window = VoiceSettings.normalizedForWakeMatch(transcript).suffix(phrase.count * 4)
    guard window.contains(phrase) else { return }
    voiceDiag("[wake] phrase hit in '\(transcript)'")
    suspend()
    onWake?()
  }

  /// Map the local speech service's opaque failures to something the user
  /// can act on. Diagnosed on this machine: assets installed, permissions
  /// granted, but on-device tasks all die with kLSR 201 "Siri and Dictation
  /// are disabled" — the fix lives in 系统设置, not in the app.
  private static func friendlyFailureReason(_ error: Error) -> String {
    let text = error.localizedDescription
    let ns = error as NSError
    if text.localizedCaseInsensitiveContains("disabled") || ns.code == 201 || ns.code == 1101 {
      return "系统「听写」未开启（系统设置 → 键盘 → 听写）"
    }
    return text
  }

  /// Backoff from the failure streak, never from when the last restart fired.
  private func scheduleRestart(regularInterval: TimeInterval?) {
    restartTimer?.invalidate()
    restartTimer = nil
    let delay: TimeInterval?
    if let regularInterval {
      delay = regularInterval
    } else {
      delay = Self.nextRestartDelay(
        failures: consecutiveFailures,
        regularInterval: taskRestartInterval,
        failureBase: errorRecoveryDelay,
        cap: Self.restartCap)
    }
    guard let delay else {
      voiceDiag("[wake] restart suppressed: failures=\(consecutiveFailures)")
      isActive = false
      return
    }
    // One line per restart: crash reports only show the swallowed-exception marker.
    voiceDiag("[wake] restart in \(String(format: "%.1f", delay))s failures=\(consecutiveFailures) regular=\(regularInterval != nil) active=\(isActive)")
    if let restartScheduler {
      restartScheduler(delay)
      return
    }
    restartTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
      Task { @MainActor in self?.beginRecognition() }
    }
  }

  private func tearDownRecognition() {
    restartTimer?.invalidate()
    restartTimer = nil
    // Mark the window where endAudio()/cancel() echoes are expected, not failures.
    isTearingDown = true
    removeVoiceTap(audioEngine, installed: tapInstalled)
    tapInstalled = false
    request?.endAudio()
    task?.cancel()
    request = nil
    task = nil
    recognizer = nil
    isActive = false
    DispatchQueue.main.async { [weak self] in
      self?.isTearingDown = false
    }
  }
}
