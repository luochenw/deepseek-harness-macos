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
  private var finalized = false
  private var finalizeFallback: DispatchWorkItem?
  private var receivedAnyResult = false
  private var retriedOnline = false

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
    let input = audioEngine.inputNode
    let format = input.outputFormat(forBus: 0)
    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
    audioEngine.prepare()
    try audioEngine.start()
    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      DispatchQueue.main.async {
        guard let self, !self.finalized, self.request === request else { return }
        if let result {
          self.receivedAnyResult = true
          self.lastTranscript = result.bestTranscription.formattedString
          self.onPartialText?(self.lastTranscript)
          if result.isFinal { self.deliverFinal() }
        } else if error != nil {
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
    audioEngine.inputNode.removeTap(onBus: 0)
    audioEngine.stop()
  }

  /// Main-queue only (recognition callback and finalize fallback both hop there).
  private func deliverFinal() {
    guard !finalized else { return }
    finalized = true
    let text = lastTranscript
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
  private static let targetSampleRate: Double = 16000

  init(endpoint: URL) {
    self.endpoint = endpoint
    self.engineNote = "本地端点识别（\(endpoint.host ?? endpoint.absoluteString)）"
  }

  func startStreaming() throws {
    finalized = false
    sampleLock.lock(); pcmSamples = Data(); sampleLock.unlock()
    let input = audioEngine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0,
          let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.targetSampleRate, channels: 1, interleaved: true),
          let converter = AVAudioConverter(from: format, to: target) else {
      throw VoiceEngineError.audioFormatUnavailable
    }
    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
      self?.appendSamples(from: buffer, using: converter, target: target)
    }
    audioEngine.prepare()
    do { try audioEngine.start() } catch {
      input.removeTap(onBus: 0)
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
    audioEngine.inputNode.removeTap(onBus: 0)
    audioEngine.stop()
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
  /// Engine mode note for status display (on-device vs. server fallback).
  var engineNote: String { transcriber.engineNote }

  private var transcriber: VoiceTranscriber
  private var synthesizer: VoiceSpeechSynthesizer
  /// True when engines were injected (tests); settings never swap them then.
  private let enginesInjected: Bool
  private var synthesizerFingerprint: String
  private var silenceTimer: Timer?
  /// Auto endpoint: stop listening this long after the last new partial result.
  // 2.0s: 1.2s finalized mid-sentence on natural zh pauses once real speech
  // had started; the initial wait is unbounded (see handlePartial).
  private let silenceEndpoint: TimeInterval = 2.0

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

  func startListening() {
    switch state {
    case .idle, .denied: break
    default: return
    }
    state = .requestingPermission
    Task { [weak self] in
      let speechGranted = await Self.requestSpeechAuthorization()
      let micGranted = await Self.requestMicrophoneAccess()
      guard let self else { return }
      guard speechGranted, micGranted else {
        self.state = .denied("请在系统设置授权麦克风与语音识别")
        return
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
    clearSilenceTimer()
    transcriber.cancelStreaming()
    partialText = ""
    state = .idle
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
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    onFinalText?(trimmed)
  }

  private func armSilenceTimer() {
    silenceTimer?.invalidate()
    silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceEndpoint, repeats: false) { [weak self] _ in
      Task { @MainActor in self?.stopListening() }
    }
  }

  private func clearSilenceTimer() {
    silenceTimer?.invalidate()
    silenceTimer = nil
  }

  // Shared with WakeWordListener (same two permissions gate both features).
  static func requestSpeechAuthorization() async -> Bool {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status == .authorized)
      }
    }
  }

  static func requestMicrophoneAccess() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return true
    case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
    default: return false
    }
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
  /// True while the microphone tap is actually running — the UI shows this so
  /// the resident-mic state is always honest.
  @Published private(set) var isActive = false
  /// Most recent start/permission failure, for display; nil when healthy.
  @Published private(set) var statusNote: String?
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
  /// Instant-failure streak feeding the circuit breaker in the task handler.
  private var consecutiveFailures = 0

  func start() {
    guard !enabled else { return }
    enabled = true
    suspended = false
    Task { [weak self] in
      let speechGranted = await VoiceController.requestSpeechAuthorization()
      let micGranted = await VoiceController.requestMicrophoneAccess()
      guard let self, self.enabled else { return }
      guard speechGranted, micGranted else {
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
      scheduleRestart(after: errorRecoveryDelay * 4)
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
    let input = audioEngine.inputNode
    let format = input.outputFormat(forBus: 0)
    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in request.append(buffer) }
    audioEngine.prepare()
    do { try audioEngine.start() } catch {
      input.removeTap(onBus: 0)
      statusNote = "唤醒词监听启动失败：\(error.localizedDescription)"
      return
    }
    isActive = true
    statusNote = nil
    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      Task { @MainActor in
        guard let self, self.request === request else { return } // stale task
        if let result {
          self.consecutiveFailures = 0
          self.handlePartial(result.bestTranscription.formattedString)
        } else if let error {
          // Circuit breaker: a fixed 1.5s retry used to thrash forever when
          // the local speech daemon was unhealthy — restarting ~40×/min,
          // grabbing the mic each time, and killing any manual talk session
          // it raced ("一闪而过"). Failures now back off exponentially and
          // give up loudly after a streak; the reason is shown, not
          // swallowed.
          self.consecutiveFailures += 1
          self.tearDownRecognition()
          if self.consecutiveFailures >= 5 {
            self.statusNote = "唤醒词监听连续失败已暂停：\(error.localizedDescription)。重开唤醒词开关可重试。"
          } else {
            self.statusNote = "唤醒词监听重试中：\(error.localizedDescription)"
            self.scheduleRestart(after: self.errorRecoveryDelay * pow(2, Double(self.consecutiveFailures)))
          }
        }
      }
    }
    scheduleRestart(after: taskRestartInterval)
  }

  private func handlePartial(_ transcript: String) {
    guard enabled, !suspended else { return }
    let phrase = VoiceSettings.normalizedForWakeMatch(VoiceSettings.wakePhrase)
    guard !phrase.isEmpty else { return }
    // Sliding window over the growing partial: only the recent tail can
    // trigger, so old chatter cannot re-match late in a long session.
    let window = VoiceSettings.normalizedForWakeMatch(transcript).suffix(phrase.count * 4)
    guard window.contains(phrase) else { return }
    suspend()
    onWake?()
  }

  private func scheduleRestart(after interval: TimeInterval) {
    restartTimer?.invalidate()
    restartTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
      Task { @MainActor in self?.beginRecognition() }
    }
  }

  private func tearDownRecognition() {
    restartTimer?.invalidate()
    restartTimer = nil
    audioEngine.inputNode.removeTap(onBus: 0)
    audioEngine.stop()
    request?.endAudio()
    task?.cancel()
    request = nil
    task = nil
    recognizer = nil
    isActive = false
  }
}
