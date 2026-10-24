import AVFoundation
import Flutter
import Speech
import StoreKit
import UIKit
import WhisperKit

/// The `relay/voice` channel. Two on-device engines sit behind it:
///
/// - **Whisper (RLY-99):** records the mic to a 16kHz mono WAV in the temp
///   directory and transcribes it with WhisperKit on stop. The audio file's
///   lifecycle is owned by Dart (WhisperKitTranscriber): this side hands back a
///   *path*, and every Dart path through stop/cancel ends in a
///   `deleteRecording` call — pinned by test/whisper_kit_transcriber_test.dart.
/// - **Apple (RE467, iOS 26):** SpeechAnalyzer + SpeechTranscriber stream words
///   live while the mic is open. No audio file exists on this path. Results,
///   asset-download progress and live interruptions go to Dart on the
///   `relay/voice/events` EventChannel (AppleSpeechTranscriber).
///
/// Also stores the engine preference in UserDefaults and answers
/// `isTestFlight` (IosVoiceEngineSettings). Registered from AppDelegate beside
/// `relay/push`, mirroring that channel.
final class VoicePlugin: NSObject, FlutterStreamHandler {
  private var channel: FlutterMethodChannel?
  private var eventSink: FlutterEventSink?
  /// The active Apple live session — an `AppleLiveSession`, typed `AnyObject`
  /// because a stored property can't be `@available(iOS 26, *)`.
  private var liveSession: AnyObject?
  private var engine: AVAudioEngine?
  private var file: AVAudioFile?
  private var converter: AVAudioConverter?
  private var targetFormat: AVAudioFormat?
  private var fileURL: URL?
  private var whisperKit: WhisperKit?
  private var transcriptionCancelled = false

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "relay/voice", binaryMessenger: messenger)
    self.channel = channel
    FlutterEventChannel(name: "relay/voice/events", binaryMessenger: messenger)
      .setStreamHandler(self)

    NotificationCenter.default.addObserver(
      self, selector: #selector(handleInterruption),
      name: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance())

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterMethodNotImplemented) }
      switch call.method {
      case "permissionStatus":
        result(self.permissionName())
      case "requestPermission":
        AVAudioApplication.requestRecordPermission { granted in
          DispatchQueue.main.async { result(granted ? "granted" : "denied") }
        }
      case "startRecording":
        self.startRecording(result: result)
      case "stopRecording", "cancelRecording":
        // Same teardown either way — what differs is only what Dart does with
        // the returned path (transcribe vs delete).
        self.stopRecording(result: result)
      case "transcribe":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          return result(FlutterError(code: "bad_args", message: "path is required", details: nil))
        }
        self.transcribe(path: path, result: result)
      case "cancelTranscription":
        self.transcriptionCancelled = true
        result(nil)
      case "deleteRecording":
        if let args = call.arguments as? [String: Any],
           let path = args["path"] as? String {
          try? FileManager.default.removeItem(atPath: path) // idempotent
        }
        result(nil)
      case "openSettings":
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url)
        }
        result(nil)
      case "liveSupport":
        self.liveSupport(result: result)
      case "requestSpeechPermission":
        self.requestSpeechPermission(result: result)
      case "downloadAsset":
        self.downloadAsset(result: result)
      case "startLive":
        self.startLive(result: result)
      case "stopLive":
        self.stopLive(result: result)
      case "cancelLive":
        self.cancelLive(result: result)
      case "enginePreference":
        result(UserDefaults.standard.string(forKey: Self.engineKey))
      case "setEnginePreference":
        guard let args = call.arguments as? [String: Any],
              let engine = args["engine"] as? String else {
          return result(FlutterError(code: "bad_args", message: "engine is required", details: nil))
        }
        UserDefaults.standard.set(engine, forKey: Self.engineKey)
        result(nil)
      case "isTestFlight":
        self.isTestFlight(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func permissionName() -> String {
    switch AVAudioApplication.shared.recordPermission {
    case .undetermined: return "notDetermined"
    case .denied: return "denied"
    case .granted: return "granted"
    @unknown default: return "denied"
    }
  }

  private func startRecording(result: @escaping FlutterResult) {
    // The mirror of startLive's guard: one engine owns the mic at a time.
    guard liveSession == nil else {
      return result(FlutterError(
        code: "recording_failed", message: "a live dictation is active", details: nil))
    }
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .measurement)
      try session.setActive(true)

      let engine = AVAudioEngine()
      let input = engine.inputNode
      let inputFormat = input.outputFormat(forBus: 0)
      // A 0Hz/0-channel input format (no usable mic) would make installTap raise
      // an uncatchable NSException; fail soft instead — Dart maps this to
      // recordingFailed and typing stays available (the spec's best-effort rule).
      guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
        teardownRecording()
        return result(FlutterError(
          code: "recording_failed", message: "microphone unavailable", details: nil))
      }
      // Whisper wants 16kHz mono; converting at the tap keeps the file — and
      // the disk cost of an uncapped clip (spec D8) — as small as possible.
      // Recording to a *file*, not memory, is what bounds an uncapped clip.
      guard
        let target = AVAudioFormat(
          commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1,
          interleaved: true),
        let converter = AVAudioConverter(from: inputFormat, to: target)
      else {
        return result(FlutterError(
          code: "recording_failed", message: "unsupported audio format", details: nil))
      }

      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-voice-\(UUID().uuidString).wav")
      // The tap writes Int16 interleaved buffers (the converter's `target`
      // output). The file must be opened with that same *processing* format:
      // init(forWriting:settings:) alone opens with the standard deinterleaved
      // Float32 processing format, and AVAudioFile.write(from:) raises an
      // uncatchable NSException on the mismatch — the RLY-99 TestFlight crash.
      // `settings` still controls the on-disk WAV format, unchanged.
      let file = try AVAudioFile(
        forWriting: url, settings: target.settings,
        commonFormat: .pcmFormatInt16, interleaved: true)

      input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
        guard let self, let converter = self.converter, let target = self.targetFormat else { return }
        let ratio = target.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
          if fed {
            status.pointee = .noDataNow
            return nil
          }
          fed = true
          status.pointee = .haveData
          return buffer
        }
        if out.frameLength > 0 { try? self.file?.write(from: out) }
      }

      engine.prepare()
      try engine.start()
      self.engine = engine
      self.file = file
      self.converter = converter
      self.targetFormat = target
      self.fileURL = url
      result(nil)
    } catch {
      teardownRecording()
      result(FlutterError(
        code: "recording_failed", message: error.localizedDescription, details: nil))
    }
  }

  private func stopRecording(result: @escaping FlutterResult) {
    let path = fileURL?.path
    teardownRecording()
    result(path)
  }

  private func teardownRecording() {
    engine?.inputNode.removeTap(onBus: 0)
    engine?.stop()
    engine = nil
    file = nil // closes the AVAudioFile
    converter = nil
    targetFormat = nil
    fileURL = nil
    try? AVAudioSession.sharedInstance()
      .setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func transcribe(path: String, result: @escaping FlutterResult) {
    transcriptionCancelled = false
    Task {
      do {
        let kit = try await self.loadedWhisperKit()
        let results = try await kit.transcribe(
          audioPath: path,
          decodeOptions: DecodingOptions(task: .transcribe, language: "en"),
          callback: { _ in self.transcriptionCancelled ? false : nil })
        let text = results.map(\.text)
          .joined(separator: " ")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async {
          // A cancelled run returns empty; Dart discards it anyway.
          result(self.transcriptionCancelled ? "" : text)
        }
      } catch let error as VoiceModelError {
        DispatchQueue.main.async {
          result(FlutterError(code: "model_load_failed", message: error.message, details: nil))
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "transcribe_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  /// Lazy, on first use (spec U2): loading ~147MB of CoreML eagerly would tax
  /// cold start for a feature most sessions never touch. Kept for the app's
  /// lifetime once loaded.
  private func loadedWhisperKit() async throws -> WhisperKit {
    if let kit = whisperKit { return kit }
    guard let resources = Bundle.main.resourceURL else {
      throw VoiceModelError(message: "no bundle resources")
    }
    let modelFolder = resources.appendingPathComponent("WhisperModel/openai_whisper-base.en")
    let tokenizerFolder = resources.appendingPathComponent("WhisperModel/tokenizer")
    guard FileManager.default.fileExists(atPath: modelFolder.path) else {
      throw VoiceModelError(
        message: "bundled model missing — run ios/scripts/fetch_whisper_model.sh")
    }
    let config = WhisperKitConfig(
      modelFolder: modelFolder.path,
      tokenizerFolder: tokenizerFolder,
      load: true,
      download: false) // offline is the premise (criterion 6) — never fetch
    do {
      let kit = try await WhisperKit(config)
      whisperKit = kit
      return kit
    } catch {
      throw VoiceModelError(message: error.localizedDescription)
    }
  }

  /// A phone call or route change mid-recording: tell Dart, which treats it
  /// exactly like a Stop tap — the partial clip transcribes (Whisper) or the
  /// words so far finalize (Apple) rather than being thrown away (spec error
  /// table). A Whisper recording keeps its `onInterrupted` method call; a live
  /// session reports on the event sink, because the channel's one Dart handler
  /// belongs to WhisperKitTranscriber.
  @objc private func handleInterruption(_ notification: Notification) {
    guard let info = notification.userInfo,
          let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
          AVAudioSession.InterruptionType(rawValue: raw) == .began
    else { return }
    DispatchQueue.main.async {
      if self.liveSession != nil {
        self.send(["type": Event.interrupted])
      } else if self.engine != nil {
        self.channel?.invokeMethod("onInterrupted", arguments: nil)
      }
    }
  }

  // MARK: - relay/voice/events

  /// Event `type`s on `relay/voice/events` — mirrored once in
  /// apple_speech_transcriber.dart.
  private enum Event {
    static let result = "result"
    static let progress = "progress"
    static let interrupted = "interrupted"
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  /// Main thread only — callers dispatch there first.
  private func send(_ event: [String: Any]) {
    eventSink?(event)
  }

  // MARK: - Apple live engine (iOS 26)

  private static func unsupported() -> FlutterError {
    FlutterError(code: "unsupported", message: "live dictation needs iOS 26", details: nil)
  }

  private func liveSupport(result: @escaping FlutterResult) {
    guard #available(iOS 26, *) else { return result("unsupported") }
    Task {
      let support = await AppleLiveSession.support()
      DispatchQueue.main.async { result(support) }
    }
  }

  /// SpeechTranscriber runs on-device under the Speech framework, so ask for
  /// Speech authorization alongside the mic; a denial falls back to Whisper.
  /// Requesting needs NSSpeechRecognitionUsageDescription in Info.plist.
  private func requestSpeechPermission(result: @escaping FlutterResult) {
    guard #available(iOS 26, *) else { return result(Self.unsupported()) }
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized:
      result("granted")
    case .notDetermined:
      SFSpeechRecognizer.requestAuthorization { status in
        DispatchQueue.main.async { result(status == .authorized ? "granted" : "denied") }
      }
    case .denied, .restricted:
      result("denied")
    @unknown default:
      result("denied")
    }
  }

  /// Progress goes out as events while the install runs; the method result is
  /// the completion. Dart may detach early — the download carries on.
  private func downloadAsset(result: @escaping FlutterResult) {
    guard #available(iOS 26, *) else { return result(Self.unsupported()) }
    Task {
      do {
        try await AppleLiveSession.downloadAsset { fraction in
          DispatchQueue.main.async { self.send(["type": Event.progress, "fraction": fraction]) }
        }
        DispatchQueue.main.async { result(nil) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "asset_download_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func startLive(result: @escaping FlutterResult) {
    guard #available(iOS 26, *) else { return result(Self.unsupported()) }
    guard engine == nil else {
      return result(FlutterError(
        code: "recording_failed", message: "a Whisper recording is active", details: nil))
    }
    // Method calls arrive on main; AppleLiveSession is @MainActor.
    MainActor.assumeIsolated {
      (liveSession as? AppleLiveSession)?.cancel()
      let session = AppleLiveSession()
      liveSession = session
      Task { @MainActor in
        do {
          try await session.start { text, isFinal in
            DispatchQueue.main.async {
              // A cancelled (or replaced) session emits nothing more.
              guard self.liveSession === session else { return }
              self.send(["type": Event.result, "text": text, "isFinal": isFinal])
            }
          }
          result(nil)
        } catch {
          // start() has already torn the session down — including when a stop
          // or cancel landed while it was still awaiting.
          if self.liveSession === session { self.liveSession = nil }
          result(FlutterError(
            code: "recording_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  /// Resolves only after every final result is on the event sink: `stop()`
  /// returns once the results task has drained, and the main queue is FIFO, so
  /// every result dispatched before it is delivered before `result(nil)`.
  private func stopLive(result: @escaping FlutterResult) {
    guard #available(iOS 26, *) else { return result(Self.unsupported()) }
    MainActor.assumeIsolated {
      guard let session = liveSession as? AppleLiveSession else { return result(nil) }
      Task { @MainActor in
        await session.stop()
        DispatchQueue.main.async {
          if self.liveSession === session { self.liveSession = nil }
          result(nil)
        }
      }
    }
  }

  private func cancelLive(result: @escaping FlutterResult) {
    guard #available(iOS 26, *) else { return result(Self.unsupported()) }
    MainActor.assumeIsolated {
      (liveSession as? AppleLiveSession)?.cancel()
      liveSession = nil // queued results check this and drop
      result(nil)
    }
  }

  // MARK: - Engine settings

  /// Which engine dictation uses: "apple" | "whisper" (IosVoiceEngineSettings).
  /// UserDefaults rather than a new Flutter dependency — see AppDelegate's
  /// primingDeferredAtKey.
  private static let engineKey = "relay.voice.engine"

  /// TestFlight builds run in the sandbox environment. Never fails: anything
  /// unexpected reads as "not TestFlight", which only hides the debug pull-down.
  private func isTestFlight(result: @escaping FlutterResult) {
    Task {
      let sandbox: Bool
      do {
        let transaction: AppTransaction
        switch try await AppTransaction.shared {
        case .verified(let verified): transaction = verified
        case .unverified(let unverified, _): transaction = unverified
        }
        sandbox = transaction.environment == .sandbox
      } catch {
        sandbox = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
      }
      DispatchQueue.main.async { result(sandbox) }
    }
  }
}

/// One live dictation: the mic tap feeds SpeechAnalyzer through an AsyncStream,
/// and SpeechTranscriber's results stream back through `onResult`. Nothing is
/// written to disk.
///
/// `@MainActor`: start() runs on main and so do cancel()/stop() (from the
/// channel handler), so every state transition is serialized — no data race on
/// `ended`, `analyzer`, `input` or `resultsTask`.
@available(iOS 26, *)
@MainActor
private final class AppleLiveSession {
  private let audioEngine = AVAudioEngine()
  private var analyzer: SpeechAnalyzer?
  private var input: AsyncStream<AnalyzerInput>.Continuation?
  private var resultsTask: Task<Void, Never>?
  /// Set by cancel() and stop(): either can land while start() is still
  /// awaiting, and start() must not go on to open the mic for a session nobody
  /// owns any more.
  private var ended = false

  /// The transcriber for the device locale, or nil when the device or locale
  /// has no SpeechTranscriber model.
  nonisolated static func transcriber() async -> SpeechTranscriber? {
    guard SpeechTranscriber.isAvailable,
          let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
    else { return nil }
    return SpeechTranscriber(
      locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
      attributeOptions: [])
  }

  /// "unsupported" | "needsDownload" | "ready" — the names Dart maps.
  nonisolated static func support() async -> String {
    guard let transcriber = await transcriber() else { return "unsupported" }
    switch await AssetInventory.status(forModules: [transcriber]) {
    case .installed: return "ready"
    case .supported, .downloading: return "needsDownload"
    case .unsupported: return "unsupported"
    @unknown default: return "unsupported"
    }
  }

  nonisolated static func downloadAsset(progress: @escaping (Double) -> Void) async throws {
    guard let transcriber = await transcriber() else { throw LiveError("unsupported locale") }
    // nil means nothing to install — the asset is already present.
    guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
    else { return }
    let observation = request.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
      progress(p.fractionCompleted)
    }
    defer { observation.invalidate() }
    try await request.downloadAndInstall()
  }

  func start(onResult: @escaping (String, Bool) -> Void) async throws {
    do {
      guard let transcriber = await Self.transcriber() else { throw LiveError("unsupported locale") }
      guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
        throw LiveError("speech model not installed")
      }
      guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
      else { throw LiveError("no compatible audio format") }

      try checkEnded()

      let analyzer = SpeechAnalyzer(modules: [transcriber])
      self.analyzer = analyzer
      try await analyzer.prepareToAnalyze(in: format)
      try checkEnded()

      resultsTask = Task {
        do {
          for try await result in transcriber.results {
            onResult(String(result.text.characters), result.isFinal)
          }
        } catch {
          // Cancellation or a finished analyzer — nothing more to deliver.
        }
      }

      let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
      input = continuation
      try await analyzer.start(inputSequence: stream)
      // No suspension point between this check and startAudio: on the main
      // actor nothing can interleave, so the mic opens only for a live session.
      try checkEnded()
      try startAudio(into: continuation, format: format)
    } catch {
      cancel()
      throw error
    }
  }

  private func checkEnded() throws {
    if ended { throw CancellationError() }
  }

  /// The same `.record` session and tap as Whisper's recorder, but each buffer
  /// is converted to the analyzer's format and yielded instead of written.
  private func startAudio(
    into continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat
  ) throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.record, mode: .measurement)
    try session.setActive(true)

    let inputNode = audioEngine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)
    // A 0Hz/0-channel input format (no usable mic) would make installTap raise
    // an uncatchable NSException; fail soft instead.
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
      throw LiveError("microphone unavailable")
    }
    guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
      throw LiveError("unsupported audio format")
    }

    inputNode.installTap(
      onBus: 0, bufferSize: 4096, format: inputFormat,
      block: Self.tap(
        converter: converter, from: inputFormat, to: format, into: continuation))

    audioEngine.prepare()
    try audioEngine.start()
  }

  /// Built outside the actor: the tap runs on the audio render thread, so the
  /// block must not inherit main-actor isolation.
  private nonisolated static func tap(
    converter: AVAudioConverter, from inputFormat: AVAudioFormat, to format: AVAudioFormat,
    into continuation: AsyncStream<AnalyzerInput>.Continuation
  ) -> AVAudioNodeTapBlock {
    { buffer, _ in
      let ratio = format.sampleRate / inputFormat.sampleRate
      let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
      guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
      var fed = false
      converter.convert(to: out, error: nil) { _, status in
        if fed {
          status.pointee = .noDataNow
          return nil
        }
        fed = true
        status.pointee = .haveData
        return buffer
      }
      if out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
    }
  }

  /// Finalizes: every final result has gone through `onResult` when this
  /// returns.
  func stop() async {
    ended = true // an in-flight start() bails before opening the mic
    stopAudio()
    try? await analyzer?.finalizeAndFinishThroughEndOfInput()
    await resultsTask?.value
    deactivate()
  }

  /// Tears down now; the caller stops delivering anything still in flight.
  func cancel() {
    ended = true
    stopAudio()
    resultsTask?.cancel()
    if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
    deactivate()
  }

  private func stopAudio() {
    audioEngine.inputNode.removeTap(onBus: 0)
    audioEngine.stop()
    input?.finish()
    input = nil
  }

  private func deactivate() {
    try? AVAudioSession.sharedInstance()
      .setActive(false, options: .notifyOthersOnDeactivation)
  }
}

struct LiveError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

struct VoiceModelError: Error {
  let message: String
}
