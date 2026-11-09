import AVFoundation
import Cocoa
import CoreAudio
import MediaPlayer
import Security

enum ReaderKeychain {
  static func read(service: String, account: String) throws -> String? {
    var result: CFTypeRef?
    let status = SecItemCopyMatching([
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service, kSecAttrAccount: account,
      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
    ] as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data,
          data.count <= 8192, let value = String(data: data, encoding: .utf8) else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    return value
  }

  static func write(_ value: String, service: String, account: String) throws {
    let data = Data(value.utf8)
    guard data.count <= 8192 else { throw ReaderPlaybackError.invalidSecret }
    let identity: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service, kSecAttrAccount: account,
    ]
    if value.isEmpty {
      let status = SecItemDelete(identity as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
      }
      return
    }
    let update = SecItemUpdate(identity as CFDictionary, [
      kSecValueData: data,
    ] as CFDictionary)
    if update == errSecSuccess { return }
    guard update == errSecItemNotFound else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(update))
    }
    var item = identity
    item[kSecValueData] = data
    item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
  }
}

enum ReaderPlaybackError: Error { case invalidSecret }

/// A single native playback owner. Accepted commands return real results;
/// delegate completions are scoped to the current player/utterance and token.
final class ReaderPlayback: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
  static let maxAudioBytes = 16 * 1024 * 1024
  private let emit: (String, [String: Any]) -> Void
  private let roots: [URL]
  private let mediaControls: Bool
  private lazy var speech: AVSpeechSynthesizer = {
    let synthesizer = AVSpeechSynthesizer()
    synthesizer.delegate = self
    return synthesizer
  }()
  private var utterance: AVSpeechUtterance?
  private var audio: AVAudioPlayer?
  private(set) var currentID: String?
  private var native = false
  private var paused = false
  private var volume: Float = 1
  private var sleepDeadline: Int64 = 0
  private var sleepWork: DispatchWorkItem?
  private var mediaActive = false
  private var targets: [(MPRemoteCommand, Any)] = []
  private let outputQueue = DispatchQueue(label: "com.fanqie.reader.audio-output")
  private var outputListener: AudioObjectPropertyListenerBlock?

  init(roots: [URL]? = nil, mediaControls: Bool = true, observeOutputChanges: Bool = true,
       emit: @escaping (String, [String: Any]) -> Void) {
    self.emit = emit
    self.roots = (roots ?? [FileManager.default.temporaryDirectory] +
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask))
      .map { $0.resolvingSymlinksInPath().standardizedFileURL }
    self.mediaControls = mediaControls
    super.init()
    if observeOutputChanges {
      let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        DispatchQueue.main.async {
          guard let self = self, let id = self.currentID else { return }
          self.emit("onAudioBecomingNoisy", ["id": id])
        }
      }
      var address = Self.outputAddress
      if AudioObjectAddPropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &address, outputQueue, listener) == noErr {
        outputListener = listener
      }
    }
  }

  deinit {
    sleepWork?.cancel()
    if let listener = outputListener {
      var address = Self.outputAddress
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &address, outputQueue, listener)
    }
    audio?.stop()
    for (command, target) in targets { command.removeTarget(target) }
  }

  private static var outputAddress: AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  }
  static var hasOutputDevice: Bool {
    var address = outputAddress
    var device: AudioObjectID = 0
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
      &address, 0, nil, &size, &device) == noErr && device != 0
  }
  static var nativeSpeechAvailable: Bool { !AVSpeechSynthesisVoice.speechVoices().isEmpty }
  static func voices() -> [[String: Any]] {
    AVSpeechSynthesisVoice.speechVoices().prefix(500).map {
      ["id": $0.identifier, "name": $0.name, "language": $0.language, "quality": $0.quality.rawValue]
    }
  }
  private static var language: String {
    Locale.preferredLanguages.first ?? "en-US"
  }

  func speak(id: String, text: String, rate: Double, voiceID: String = "") -> Bool {
    guard !id.isEmpty, id.utf8.count <= 512, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          text.utf16.count <= 4096, rate.isFinite, Self.hasOutputDevice else { return false }
    let voice = voiceID.isEmpty
      ? AVSpeechSynthesisVoice(language: "zh-CN")
        ?? AVSpeechSynthesisVoice(language: Self.language)
        ?? AVSpeechSynthesisVoice.speechVoices().first
      : AVSpeechSynthesisVoice(identifier: voiceID)
    guard let selected = voice else { return false }
    _ = stop()
    let request = AVSpeechUtterance(string: text)
    request.voice = selected
    request.rate = min(AVSpeechUtteranceMaximumSpeechRate,
      max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(rate)))
    request.volume = volume
    currentID = id
    native = true
    paused = false
    utterance = request
    speech.speak(request)
    return true
  }

  func validateAudio(_ file: URL) -> Bool {
    let original = file.standardizedFileURL
    guard original.isFileURL,
          original.lastPathComponent.range(
            of: #"^tts_[0-9]+-[0-9]+-[0-9]+-[0-9]+\.(mp3|wav)$"#,
            options: .regularExpression) != nil else { return false }
    let resolved = original.resolvingSymlinksInPath().standardizedFileURL
    guard roots.contains(where: { resolved.path.hasPrefix($0.path + "/") }),
          let values = try? original.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
          values.isRegularFile == true, values.isSymbolicLink != true,
          let size = values.fileSize, size > 12, size <= Self.maxAudioBytes else { return false }
    return true
  }
  func play(id: String, file: URL) -> Bool {
    guard !id.isEmpty, id.utf8.count <= 512, validateAudio(file), Self.hasOutputDevice else { return false }
    do {
      let player = try AVAudioPlayer(contentsOf: file)
      guard player.duration.isFinite, player.duration > 0,
            player.duration <= 1800, player.prepareToPlay() else { return false }
      _ = stop()
      player.delegate = self
      player.volume = volume
      // The compatible endpoint has already synthesized at `speed`.
      // Applying that rate again would double the requested speed.
      player.enableRate = false
      currentID = id
      native = false
      paused = false
      audio = player
      guard player.play() else { _ = stop(); return false }
      return true
    } catch { return false }
  }
  @discardableResult func stop(id: String? = nil) -> Bool {
    if let id = id, currentID != id { return false }
    currentID = nil // Invalidate before stopping: late delegates cannot complete a new run.
    let wasNative = native
    utterance = nil
    audio?.delegate = nil
    audio?.stop()
    audio = nil
    native = false
    paused = false
    if wasNative { speech.stopSpeaking(at: .immediate) }
    return true
  }
  func stopNative() -> Bool { native ? stop() : true }
  func stopAudio() -> Bool { native ? true : stop() }
  func pauseAudio(id: String?) -> Bool {
    guard !native, currentID != nil, id == nil || id == currentID, let player = audio else { return false }
    player.pause()
    paused = true
    return true
  }
  func resumeAudio(id: String?) -> Bool {
    guard !native, currentID != nil, id == nil || id == currentID, let player = audio else { return false }
    paused = false
    return player.play()
  }
  func setVolume(_ value: Double) -> Bool {
    guard value.isFinite, value >= 0, value <= 1 else { return false }
    volume = Float(value)
    audio?.volume = volume
    utterance?.volume = volume
    return true
  }
  func playbackState() -> [String: Any] {
    ["id": currentID.map { $0 as Any } ?? NSNull(), "playing": currentID != nil && !paused &&
      (native ? speech.isSpeaking : audio?.isPlaying == true),
     "native": native, "paused": paused, "volume": volume,
     "deadline": sleepDeadline, "position_ms": Int((audio?.currentTime ?? 0) * 1000)]
  }
  func setDeadline(_ milliseconds: Int64) -> Bool {
    guard milliseconds >= 0 else { return false }
    sleepWork?.cancel()
    sleepDeadline = milliseconds
    guard milliseconds > 0 else { sleepWork = nil; return true }
    let delay = max(0, Double(milliseconds) / 1000 - Date().timeIntervalSince1970)
    guard delay <= 86400 + 1 else { sleepDeadline = 0; return false }
    let work = DispatchWorkItem { [weak self] in
      guard let self = self, self.sleepDeadline == milliseconds else { return }
      _ = self.stop()
      self.sleepDeadline = 0
      self.emit("onAudioSleepTimer", ["deadline": milliseconds])
    }
    sleepWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    return true
  }
  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish request: AVSpeechUtterance) {
    guard native, utterance === request, let id = currentID else { return }
    currentID = nil
    utterance = nil
    emit("onTtsComplete", ["id": id])
  }
  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel request: AVSpeechUtterance) {
    guard native, utterance === request, let id = currentID else { return }
    currentID = nil
    utterance = nil
    emit("onTtsError", ["id": id])
  }
  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    guard audio === player, let id = currentID else { return }
    currentID = nil
    audio = nil
    emit(flag ? "onAudioComplete" : "onAudioError", ["id": id])
  }
  func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    guard audio === player, let id = currentID else { return }
    _ = stop()
    emit("onAudioError", ["id": id])
  }
  private func installMediaCommands() {
    guard mediaControls, targets.isEmpty else { return }
    let center = MPRemoteCommandCenter.shared()
    for (command, method) in [
      (center.playCommand, "onMediaPlay"), (center.pauseCommand, "onMediaPause"),
      (center.nextTrackCommand, "onMediaNext"), (center.previousTrackCommand, "onMediaPrev"),
      (center.stopCommand, "onMediaStop"),
    ] {
      let target = command.addTarget { [weak self] _ in
        guard let self = self else { return .commandFailed }
        var accepted = false
        let action = {
          if self.mediaActive { self.emit(method, [:]); accepted = true }
        }
        if Thread.isMainThread { action() }
        else { DispatchQueue.main.sync(execute: action) }
        return accepted ? .success : .noSuchContent
      }
      targets.append((command, target))
    }
  }
  func updateMedia(title: String, subtitle: String, playing: Bool, active: Bool) {
    guard mediaControls else { return }
    mediaActive = active
    if active {
      installMediaCommands()
      MPNowPlayingInfoCenter.default().nowPlayingInfo = [
        MPMediaItemPropertyTitle: String(title.prefix(256)),
        MPMediaItemPropertyAlbumTitle: String(subtitle.prefix(256)),
        MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
      ]
      MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
    } else {
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
    let center = MPRemoteCommandCenter.shared()
    center.playCommand.isEnabled = active && !playing
    center.pauseCommand.isEnabled = active && playing
    center.nextTrackCommand.isEnabled = active
    center.previousTrackCommand.isEnabled = active
    center.stopCommand.isEnabled = active
  }
  func release() {
    _ = stop()
    _ = setDeadline(0)
    updateMedia(title: "", subtitle: "", playing: false, active: false)
    for (command, target) in targets { command.removeTarget(target) }
    targets.removeAll()
  }
}
