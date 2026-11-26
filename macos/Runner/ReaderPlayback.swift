import AVFoundation
import Cocoa
import CoreAudio
import MediaPlayer
import Security

enum ReaderKeychain {
  static func isValidAccount(_ account: String) -> Bool {
    !account.isEmpty && account.utf8.count <= 256 && !account.contains("\0")
  }

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
  private static let allowedAudioFilePattern =
    #"^(?:tts_[0-9]+-[0-9]+-[0-9]+-[0-9]+|[0-9a-f]{64}|immersive_preview_-?[0-9]+)\.(mp3|wav)$"#
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
  private var nextAudio: AVAudioPlayer?
  private var nextID: String?
  private var nextAfterID: String?
  private var nextPrepared = false
  private var nextGapMs: Int = 0
  private var preloadGeneration: UInt64 = 0
  private var pendingGapWork: DispatchWorkItem?
  private var pendingTransitionAudio: AVAudioPlayer?
  private let preloadQueue = DispatchQueue(label: "com.fanqie.reader.audio-preload", qos: .userInitiated)
  private(set) var currentID: String?
  private var native = false
  private var paused = false
  private var volume: Float = 1
  private var playbackRate: Float = 1
  private var preservePitch = true
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
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask) +
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask))
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
    clearPreloaded()
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
            of: Self.allowedAudioFilePattern,
            options: .regularExpression) != nil else { return false }
    let resolved = original.resolvingSymlinksInPath().standardizedFileURL
    guard roots.contains(where: { resolved.path.hasPrefix($0.path + "/") }),
          let values = try? original.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
          values.isRegularFile == true, values.isSymbolicLink != true,
          let size = values.fileSize, size > 12, size <= Self.maxAudioBytes else { return false }
    return true
  }

  /// 通过原生 AVAudioPlayer 校验音频文件（兼容 .tmp 临时文件）可解码并返回真实时长毫秒数
  static func probeAudioDuration(file: URL) -> [String: Any] {
    let original = file.standardizedFileURL
    guard original.isFileURL,
          let values = try? original.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
          values.isRegularFile == true, values.isSymbolicLink != true,
          let size = values.fileSize, size > 12, size <= maxAudioBytes else {
      return ["valid": false, "durationMs": 0]
    }
    do {
      let data = try Data(contentsOf: original, options: .mappedIfSafe)
      let player = try AVAudioPlayer(data: data)
      guard player.duration.isFinite, player.duration > 0, player.duration <= 3600 else {
        return ["valid": false, "durationMs": 0]
      }
      let isWav = data.count >= 12 &&
        data[0] == 0x52 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x46 &&
        data[8] == 0x57 && data[9] == 0x41 && data[10] == 0x56 && data[11] == 0x45
      let durationMs = max(1, Int((player.duration * 1000.0).rounded()))
      return [
        "valid": true,
        "durationMs": durationMs,
        "mime": isWav ? "audio/wav" : "audio/mpeg",
      ]
    } catch {
      return ["valid": false, "durationMs": 0]
    }
  }

  /// 通过 macOS 原生 AVSpeechSynthesizer 离线合成为 WAV 音频文件，供沉浸式听书旁白/角色无缝复用
  static func synthesizeNativeTtsToFile(
    text: String,
    rate: Double,
    voiceID: String,
    outputPath: String,
    completion: @escaping ([String: Any]) -> Void
  ) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !outputPath.isEmpty else {
      completion(["ok": false, "error": "待合成文本或输出路径为空"])
      return
    }
    guard #available(macOS 10.15, *) else {
      completion(["ok": false, "error": "当前 macOS 版本不支持系统语音离线合成"])
      return
    }
    let voice = (voiceID.isEmpty || voiceID == "default")
      ? (AVSpeechSynthesisVoice(language: "zh-CN")
        ?? AVSpeechSynthesisVoice(language: Self.language)
        ?? AVSpeechSynthesisVoice.speechVoices().first)
      : (AVSpeechSynthesisVoice(identifier: voiceID)
        ?? AVSpeechSynthesisVoice(language: "zh-CN")
        ?? AVSpeechSynthesisVoice.speechVoices().first)
    guard let selected = voice else {
      completion(["ok": false, "error": "未找到可用的系统朗读语音"])
      return
    }

    let outURL = URL(fileURLWithPath: outputPath)
    try? FileManager.default.createDirectory(
      at: outURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? FileManager.default.removeItem(at: outURL)

    let utterance = AVSpeechUtterance(string: trimmed)
    utterance.voice = selected
    utterance.rate = min(
      AVSpeechUtteranceMaximumSpeechRate,
      max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(rate))
    )

    let synth = AVSpeechSynthesizer()
    var audioFile: AVAudioFile?
    var finished = false
    let lock = NSLock()

    func finish(_ payload: [String: Any]) {
      lock.lock()
      if finished {
        lock.unlock()
        return
      }
      finished = true
      audioFile = nil
      lock.unlock()
      DispatchQueue.main.async { completion(payload) }
    }

    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 25.0) {
      finish(["ok": false, "error": "系统语音合成超时"])
    }

    synth.write(utterance) { buffer in
      guard let pcm = buffer as? AVAudioPCMBuffer else {
        finish(["ok": false, "error": "系统语音返回非 PCM 音频缓冲区"])
        return
      }
      if pcm.frameLength == 0 {
        lock.lock()
        audioFile = nil
        lock.unlock()
        let size = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int64) ?? 0
        if size > 44 {
          finish(["ok": true, "filePath": outURL.path])
        } else {
          finish(["ok": false, "error": "系统语音输出音频为空"])
        }
        return
      }
      do {
        lock.lock()
        defer { lock.unlock() }
        if finished { return }
        if audioFile == nil {
          audioFile = try AVAudioFile(
            forWriting: outURL,
            settings: pcm.format.settings,
            commonFormat: pcm.format.commonFormat,
            interleaved: pcm.format.isInterleaved
          )
        }
        try audioFile?.write(from: pcm)
      } catch {
        finish(["ok": false, "error": "写入系统语音音频失败：\(error.localizedDescription)"])
      }
    }
  }

  /// 查询目标路径所在文件系统的真实剩余磁盘空间字节数
  static func freeDiskBytes(at rawPath: String) -> Int64 {
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    var target = trimmed.isEmpty
      ? FileManager.default.homeDirectoryForCurrentUser
      : URL(fileURLWithPath: trimmed).standardizedFileURL
    while !FileManager.default.fileExists(atPath: target.path) {
      let parent = target.deletingLastPathComponent()
      if parent.path == target.path { break }
      target = parent
    }
    do {
      let values = try target.resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey,
      ])
      if let important = values.volumeAvailableCapacityForImportantUsage, important >= 0 {
        return important
      }
      if let available = values.volumeAvailableCapacity, available >= 0 {
        return Int64(available)
      }
      return -1
    } catch {
      return -1
    }
  }

  func play(id: String, file: URL, rate: Double = 1.0, preservePitch: Bool = true,
            startPositionMs: Int = 0) -> Bool {
    guard !id.isEmpty, id.utf8.count <= 512, rate.isFinite, startPositionMs >= 0,
          validateAudio(file), Self.hasOutputDevice else { return false }
    let clampedRate = Float(min(2.0, max(0.5, rate)))
    do {
      let player = try AVAudioPlayer(contentsOf: file)
      guard player.duration.isFinite, player.duration > 0, player.duration <= 1800 else {
        return false
      }
      player.enableRate = true
      player.rate = clampedRate
      guard player.prepareToPlay() else { return false }
      if startPositionMs > 0 {
        let seekSeconds = Double(startPositionMs) / 1000.0
        if seekSeconds < player.duration - 0.1 {
          player.currentTime = seekSeconds
        }
      }
      _ = stop()
      player.delegate = self
      player.volume = volume
      playbackRate = clampedRate
      self.preservePitch = preservePitch
      currentID = id
      native = false
      paused = false
      audio = player
      guard player.play() else { _ = stop(); return false }
      return true
    } catch { return false }
  }

  /// 异步预热下一音频段至双缓冲槽位，消除切段卡顿并支持自然呼吸停顿
  func preloadNext(afterID: String, id: String, file: URL, rate: Double = 1.0,
                   preservePitch: Bool = true, gapMs: Int = 0) -> Bool {
    clearPreloaded()
    guard !afterID.isEmpty, !id.isEmpty, id.utf8.count <= 512, !native,
          afterID == currentID, audio != nil, rate.isFinite,
          validateAudio(file), Self.hasOutputDevice else { return false }
    let clampedGap = min(3000, max(0, gapMs))
    let clampedRate = Float(min(2.0, max(0.5, rate)))
    nextID = id
    nextAfterID = afterID
    nextPrepared = false
    nextGapMs = clampedGap
    preloadGeneration &+= 1
    let gen = preloadGeneration
    let initialVolume = volume
    preloadQueue.async { [weak self] in
      let prepared: AVAudioPlayer?
      do {
        let player = try AVAudioPlayer(contentsOf: file)
        if player.duration.isFinite, player.duration > 0, player.duration <= 1800 {
          player.enableRate = true
          player.rate = clampedRate
          player.volume = initialVolume
          prepared = player.prepareToPlay() ? player : nil
        } else {
          prepared = nil
        }
      } catch {
        prepared = nil
      }
      DispatchQueue.main.async {
        guard let self = self else { return }
        guard self.preloadGeneration == gen,
              !self.native,
              self.currentID == afterID,
              self.nextID == id,
              self.audio != nil,
              let ready = prepared else {
          if self.preloadGeneration == gen {
            self.clearPreloaded()
          }
          return
        }
        ready.volume = self.volume
        ready.rate = self.playbackRate
        self.nextAudio = ready
        self.nextPrepared = true
      }
    }
    return true
  }

  func clearPreloaded() {
    preloadGeneration &+= 1
    pendingGapWork?.cancel()
    pendingGapWork = nil
    pendingTransitionAudio?.delegate = nil
    pendingTransitionAudio?.stop()
    pendingTransitionAudio = nil
    nextAudio?.delegate = nil
    nextAudio?.stop()
    nextAudio = nil
    nextID = nil
    nextAfterID = nil
    nextPrepared = false
    nextGapMs = 0
  }

  private func tryAdvanceToPreloaded(completedID: String) -> Bool {
    guard let next = nextAudio, let targetID = nextID,
          nextPrepared, nextAfterID == completedID else {
      clearPreloaded()
      return false
    }
    let gap = nextGapMs
    // 先接管所有权，防止被并发 clearPreloaded 误释放
    preloadGeneration &+= 1
    nextAudio = nil
    nextID = nil
    nextAfterID = nil
    nextPrepared = false
    nextGapMs = 0
    pendingTransitionAudio = next

    let startPreloaded: () -> Void = { [weak self] in
      guard let self = self else { return }
      self.pendingGapWork = nil
      guard let ready = self.pendingTransitionAudio,
            self.currentID == completedID || self.currentID == targetID else {
        self.pendingTransitionAudio?.delegate = nil
        self.pendingTransitionAudio?.stop()
        self.pendingTransitionAudio = nil
        return
      }
      self.pendingTransitionAudio = nil
      self.audio?.delegate = nil
      self.audio?.stop()
      ready.delegate = self
      ready.volume = self.volume
      ready.rate = self.playbackRate
      self.audio = ready
      self.currentID = targetID
      self.native = false
      self.paused = false
      if ready.play() {
        self.emit("onAudioTransition", ["completedId": completedID, "startedId": targetID])
      } else {
        ready.delegate = nil
        if self.audio === ready { self.audio = nil }
        self.currentID = nil
        self.emit("onAudioComplete", ["id": completedID])
      }
    }

    if gap <= 0 {
      startPreloaded()
    } else {
      let work = DispatchWorkItem(block: startPreloaded)
      pendingGapWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(gap), execute: work)
    }
    return true
  }

  @discardableResult func stop(id: String? = nil) -> Bool {
    if let id = id, currentID != id { return false }
    clearPreloaded()
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
    clearPreloaded()
    player.pause()
    paused = true
    return true
  }
  func resumeAudio(id: String?) -> Bool {
    guard !native, currentID != nil, id == nil || id == currentID, let player = audio else { return false }
    paused = false
    player.rate = playbackRate
    return player.play()
  }
  func setVolume(_ value: Double) -> Bool {
    guard value.isFinite, value >= 0, value <= 1 else { return false }
    volume = Float(value)
    audio?.volume = volume
    nextAudio?.volume = volume
    pendingTransitionAudio?.volume = volume
    utterance?.volume = volume
    return true
  }
  func setPlaybackRate(_ rate: Double, preservePitch: Bool = true) -> Bool {
    guard rate.isFinite else { return false }
    playbackRate = Float(min(2.0, max(0.5, rate)))
    self.preservePitch = preservePitch
    audio?.rate = playbackRate
    nextAudio?.rate = playbackRate
    pendingTransitionAudio?.rate = playbackRate
    return true
  }
  func audioPosition() -> [String: Any] {
    let playing = !native && !paused && audio?.isPlaying == true
    let positionMs = Int(max(0, (audio?.currentTime ?? 0) * 1000))
    let durationMs = Int(max(0, (audio?.duration ?? 0) * 1000))
    return [
      "id": currentID.map { $0 as Any } ?? NSNull(),
      "playing": playing,
      "positionMs": positionMs,
      "durationMs": durationMs,
    ]
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
    if flag && !native && tryAdvanceToPreloaded(completedID: id) {
      return
    }
    clearPreloaded()
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
