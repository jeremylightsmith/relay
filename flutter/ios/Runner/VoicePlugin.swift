import AVFoundation
import Flutter
import UIKit
import WhisperKit

/// The `relay/voice` channel (RLY-99): records the mic to a 16kHz mono WAV in
/// the temp directory and transcribes it on-device with WhisperKit on stop.
/// Registered from AppDelegate beside `relay/push`, mirroring that channel.
///
/// The audio file's lifecycle is owned by Dart (WhisperKitTranscriber): this
/// side hands back a *path*, and every Dart path through stop/cancel ends in a
/// `deleteRecording` call — pinned by test/whisper_kit_transcriber_test.dart.
final class VoicePlugin: NSObject {
  private var channel: FlutterMethodChannel?
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
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .measurement)
      try session.setActive(true)

      let engine = AVAudioEngine()
      let input = engine.inputNode
      let inputFormat = input.outputFormat(forBus: 0)
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
      let file = try AVAudioFile(forWriting: url, settings: target.settings)

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
  /// exactly like a Stop tap — the partial clip transcribes rather than being
  /// thrown away (spec error table).
  @objc private func handleInterruption(_ notification: Notification) {
    guard let info = notification.userInfo,
          let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
          AVAudioSession.InterruptionType(rawValue: raw) == .began,
          engine != nil
    else { return }
    DispatchQueue.main.async { self.channel?.invokeMethod("onInterrupted", arguments: nil) }
  }
}

struct VoiceModelError: Error {
  let message: String
}
